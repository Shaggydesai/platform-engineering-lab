#!/usr/bin/env bash
# Cluster smoke test - Module 02 deliverable. Works against whatever kube context is current.
set -euo pipefail
#
#   make smoke            interactive, asks which context it is about to touch
#   YES=1 make smoke      no prompt - for Ansible (Module 03) and CI
#
# It creates a throwaway namespace and deletes it on exit, including on failure.
NS=smoke-$RANDOM
ctx=$(kubectl config current-context)
echo "context: $ctx"
if [ "${YES:-}" != 1 ]; then
  # The context guard is not paranoia: this repo will have three contexts, two of
  # them in the cloud, and the GKE one costs money.
  read -rp "run the smoke test against '$ctx'? [y/N] " a; [ "$a" = y ] || exit 1
fi

# On success the namespace goes away. On FAILURE it is kept, because a test that
# destroys its own evidence forces you to reproduce the failure before you can look at
# it - and an intermittent failure may not reproduce.
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then
    kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  else
    echo
    echo "FAILED. Namespace $NS has been KEPT so you can look at it:"
    echo "  kubectl -n $NS get pod,svc,endpointslice -o wide"
    echo "  kubectl -n $NS exec p-cp01 -- curl -v -m5 http://web.$NS.svc.cluster.local"
    echo "  kubectl delete ns $NS          # when you are done"
  fi
}
trap cleanup EXIT
kubectl create ns "$NS" >/dev/null

echo "1/5 nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null
kubectl get nodes -o wide

echo "2/5 scheduling on every node"
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n "$NS" run "p-${n##*-}" --image=nicolaka/netshoot --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$n\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    -- sleep 300 >/dev/null
done
kubectl -n "$NS" wait --for=condition=Ready pod --all --timeout=120s >/dev/null

echo "3/5 pod-to-pod across nodes (every ordered pair)"
# EVERY pair, not one. The first version of this test pinged pods[0] -> pods[1], which on a
# three-node cluster happened to be control-plane -> worker, and never touched the
# worker-to-worker path where real traffic actually lives. A tunnel can be broken in one
# direction, or between one pair of nodes, and a single ping will not find it.
pods=($(kubectl -n "$NS" get pod -o jsonpath='{.items[*].metadata.name}'))
if [ "${#pods[@]}" -lt 2 ]; then
  echo "    single node, skipped"
else
  declare -A ip
  for p in "${pods[@]}"; do
    ip[$p]=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.podIP}')
  done
  pairs=0
  for src in "${pods[@]}"; do
    for dst in "${pods[@]}"; do
      [ "$src" = "$dst" ] && continue
      if kubectl -n "$NS" exec "$src" -- ping -c2 -W2 "${ip[$dst]}" >/dev/null 2>&1; then
        printf '    %-10s -> %-10s %s  ok\n' "$src" "$dst" "${ip[$dst]}"
      else
        printf '    %-10s -> %-10s %s  FAILED\n' "$src" "$dst" "${ip[$dst]}"
        echo "    One direction of one tunnel is broken. Look at:"
        echo "      cilium status --verbose      (drops, tunnel state)"
        echo "      hubble observe --pod $src    (where the packet went)"
        exit 1
      fi
      pairs=$((pairs+1))
    done
  done
  echo "    $pairs of $pairs paths work"
fi

echo "4/5 cluster DNS"
kubectl -n "$NS" exec "${pods[0]}" -- nslookup kubernetes.default.svc.cluster.local >/dev/null
echo "    resolves"

echo "5/5 Service routing"
kubectl -n "$NS" create deploy web --image=nginx:alpine --replicas=2 >/dev/null
kubectl -n "$NS" expose deploy web --port=80 >/dev/null
kubectl -n "$NS" rollout status deploy/web --timeout=120s >/dev/null

# A pod being Ready is not the same as its Service being routable. The chain is:
# pod Ready -> EndpointSlice updated -> every node's kube-proxy writes iptables rules.
# `rollout status` returns after the first link. nginx has no readiness probe, so
# "Available" only means the container started. A single-shot curl immediately after is
# a race, and the first version of this test lost it.
kubectl -n "$NS" wait --for=jsonpath='{.endpoints[0].conditions.ready}'=true \
  endpointslice -l kubernetes.io/service-name=web --timeout=60s >/dev/null
clusterip=$(kubectl -n "$NS" get svc web -o jsonpath='{.spec.clusterIP}')

# Three probes, narrowest first, so a failure says WHICH layer broke rather than
# "the service is unreachable":
#   backend  - a pod IP directly        -> is nginx actually serving?
#   clusterip- the virtual IP           -> did kube-proxy program the rules?
#   dns name - the full name            -> does cluster DNS resolve the service?
backend=$(kubectl -n "$NS" get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
probe() {
  local what=$1 url=$2
  for _ in $(seq 1 15); do
    if kubectl -n "$NS" exec "${pods[0]}" -- curl -sf -m3 "$url" >/dev/null 2>&1; then
      printf '    %-10s %-34s ok\n' "$what" "$url"; return 0
    fi
    sleep 2
  done
  printf '    %-10s %-34s FAILED\n' "$what" "$url"
  return 1
}

probe backend  "http://$backend"
probe clusterip "http://$clusterip"
probe dns      "http://web.$NS.svc.cluster.local"

echo
echo "smoke test passed on $ctx"
echo
# Not a check, just context for whoever is reading the output. If the CNI is unhappy the
# five checks above may still pass while something is quietly degraded.
if command -v cilium >/dev/null 2>&1; then
  cilium status --brief 2>/dev/null || true
fi
kubectl get nodes -o custom-columns=NODE:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
