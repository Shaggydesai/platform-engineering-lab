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

echo "1/7 nodes Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null
kubectl get nodes -o wide

echo "2/7 scheduling on every node"
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n "$NS" run "p-${n##*-}" --image=nicolaka/netshoot --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$n\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    -- sleep 300 >/dev/null
done
kubectl -n "$NS" wait --for=condition=Ready pod --all --timeout=120s >/dev/null

echo "3/7 pod-to-pod across nodes (every ordered pair)"
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

echo "4/7 cluster DNS"
kubectl -n "$NS" exec "${pods[0]}" -- nslookup kubernetes.default.svc.cluster.local >/dev/null
echo "    resolves"

echo "5/7 Service routing"
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
#   clusterip- the virtual IP           -> is SOMETHING programming Services?
#                                         (Cilium's eBPF maps now; kube-proxy's
#                                          iptables chains before Module 05)
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

echo "6/7 NodePort from every node"
# Added after a cluster passed all five checks above with NO NodePort implementation
# whatsoever. kube-proxy had been deleted while every Cilium agent was still running
# kubeProxyReplacement: false, so nothing served NodePort, externalIPs, HostPort, or
# ClusterIP from a node's own netns - and the checks above missed all of it, because every
# one of them probes from INSIDE a pod, where Cilium's socket-LB handles ClusterIP whether
# or not it is in replacement mode.
#
# This probe is different in two ways that are the whole point:
#   - it originates from the WORKSTATION, outside the cluster, not from a pod;
#   - it hits ALL THREE nodes, including the two with no backend pod on them.
# A node with no local backend has to forward to one that has it. That forwarding is the
# part kube-proxy used to own, so this is the narrowest check that fails when nothing has
# taken the job over.
kubectl -n "$NS" expose deployment web --name=web-np --type=NodePort --port=80 >/dev/null
nodeport=$(kubectl -n "$NS" get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')
backend_node=$(kubectl -n "$NS" get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
echo "    backend pod is on $backend_node; port $nodeport"

np_ok=0 np_total=0
# Name and address in ONE query, as pairs. Looking the name up separately by
# .status.addresses[0].address assumes an order the API does not promise - addresses can
# come back Hostname-first, and then every node prints as blank.
while read -r name addr; do
  [[ -z "${addr:-}" ]] && continue
  np_total=$((np_total + 1))
  code=000
  for _ in $(seq 1 10); do
    # No `|| echo 000`: curl's -w already prints 000 when the request fails, so the fallback
    # appended a second one and the output read "000000". `|| true` keeps set -e happy without
    # writing anything.
    code=$(curl -sS -o /dev/null -m 3 -w '%{http_code}' "http://$addr:$nodeport" 2>/dev/null || true)
    code=${code:-000}
    [[ $code == 200 ]] && break
    sleep 2
  done
  if [[ $code == 200 ]]; then
    np_ok=$((np_ok + 1))
    extra=""
    [[ "$name" != "$backend_node" ]] && extra="  (forwarded - no local backend)"
    printf '    %-10s %-22s %s%s\n' "$name" "$addr:$nodeport" "$code" "$extra"
  else
    printf '    %-10s %-22s %s  FAILED\n' "$name" "$addr:$nodeport" "$code"
  fi
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
echo "    $np_ok of $np_total nodes serve the NodePort"
[[ $np_ok -eq $np_total ]]

echo "7/7 LoadBalancer address, announced on the node network"
# Deliberately separate from the Gateway, and this ordering is the point.
#
# A Cilium Gateway's address goes through THREE things: LB-IPAM allocates it, the L2
# announcement policy answers ARP for it, and the Gateway's L7 proxy serves it. There is an open
# upstream issue where exactly that combination is reachable from inside the cluster and times
# out from outside, with the Gateway's load-balancer entry showing no backends and marked
# l7-load-balancer (cilium/cilium#43819, reported on 1.18.x, no root cause).
#
# So this step tests the first two WITHOUT the third: a plain type=LoadBalancer Service in front
# of the same nginx the steps above used, which gets a real backend and the ordinary datapath.
# If this passes and the Gateway does not, the fault is isolated to the L7 path and not to L2
# announcements - and that distinction takes about an hour to establish without a probe like
# this one.
#
# Reuses the existing `web` deployment rather than adding a workload or a second image.
if ! kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 \
   || [[ -z "$(kubectl get ciliumloadbalancerippools.cilium.io -o name 2>/dev/null)" ]]; then
  printf '    %s\n' "no CiliumLoadBalancerIPPool in this cluster - skipped"
  printf '    %s\n' "(expected before Module 05's platform-ingress Application is synced)"
else
  kubectl -n "$NS" expose deployment web --name=web-lb --type=LoadBalancer --port=80 >/dev/null
  lbip=""
  for _ in $(seq 1 30); do
    lbip=$(kubectl -n "$NS" get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$lbip" ]] && break
    sleep 2
  done
  if [[ -z "$lbip" ]]; then
    # <pending> here means ALLOCATION failed, which is a pool problem, not a network one. The
    # condition says which: no_pool when nothing selects this Service, out_of_ips when the
    # range is exhausted.
    printf '    %-28s %s\n' "allocation" "FAILED - no address assigned"
    kubectl -n "$NS" get svc web-lb -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
    false
  else
    printf '    %-28s %s\n' "allocated from pool" "$lbip"
    # Announcement is the separate half, and the one that is invisible in `kubectl get svc`: an
    # address can be allocated and advertised nowhere. Curling it from the workstation is the
    # only thing that distinguishes the two.
    code=000
    for _ in $(seq 1 15); do
      code=$(curl -sS -o /dev/null -m 3 -w '%{http_code}' "http://$lbip" 2>/dev/null || true)
      code=${code:-000}
      [[ $code == 200 ]] && break
      sleep 2
    done
    holder=$(kubectl get leases -n kube-system -o json 2>/dev/null \
      | jq -r --arg ip "$lbip" '.items[] | select(.metadata.name | test("cilium-l2announce")) | .spec.holderIdentity' 2>/dev/null \
      | head -1 || true)
    if [[ $code == 200 ]]; then
      printf '    %-28s %s%s\n' "answers from workstation" "$code" "${holder:+  (announced by $holder)}"
    else
      printf '    %-28s %s  FAILED - allocated but nothing answers ARP\n' "answers from workstation" "$code"
      printf '    %s\n' "check: kubectl get ciliuml2announcementpolicies.cilium.io -o yaml"
      printf '    %s\n' "       kubectl get leases -n kube-system | grep l2announce"
      false
    fi
  fi
fi

echo
echo "smoke test passed on $ctx"
echo
# Not a check, just context for whoever is reading the output. If the CNI is unhappy the
# five checks above may still pass while something is quietly degraded.
if command -v cilium >/dev/null 2>&1; then
  cilium status --brief 2>/dev/null || true
fi
kubectl get nodes -o custom-columns=NODE:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
