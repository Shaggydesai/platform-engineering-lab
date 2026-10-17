#!/usr/bin/env bash
# Cluster smoke test - Module 02 deliverable. Works against whatever kube context is current.
set -euo pipefail
NS=smoke-$RANDOM
ctx=$(kubectl config current-context)
echo "context: $ctx"
read -rp "run the smoke test against '$ctx'? [y/N] " a; [ "$a" = y ] || exit 1

cleanup() { kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
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

echo "3/5 pod-to-pod across nodes"
pods=($(kubectl -n "$NS" get pod -o jsonpath='{.items[*].metadata.name}'))
if [ "${#pods[@]}" -gt 1 ]; then
  target=$(kubectl -n "$NS" get pod "${pods[1]}" -o jsonpath='{.status.podIP}')
  kubectl -n "$NS" exec "${pods[0]}" -- ping -c3 -W2 "$target" >/dev/null
  echo "    ${pods[0]} -> ${pods[1]} ok"
else
  echo "    single node, skipped"
fi

echo "4/5 cluster DNS"
kubectl -n "$NS" exec "${pods[0]}" -- nslookup kubernetes.default.svc.cluster.local >/dev/null
echo "    resolves"

echo "5/5 Service routing"
kubectl -n "$NS" create deploy web --image=nginx:alpine --replicas=2 >/dev/null
kubectl -n "$NS" expose deploy web --port=80 >/dev/null
kubectl -n "$NS" rollout status deploy/web --timeout=120s >/dev/null
kubectl -n "$NS" exec "${pods[0]}" -- curl -sf -m5 http://web."$NS".svc.cluster.local >/dev/null
echo "    service reachable"

echo
echo "smoke test passed on $ctx"
