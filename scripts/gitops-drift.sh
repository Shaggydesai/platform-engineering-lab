#!/usr/bin/env bash
# Find things running in the cluster that nothing in Git claims to own.
#
#   make gitops-drift
#
# ADR-0009 ends with a claim: "anything in the cluster that is neither in gitops/bootstrap/ nor
# owned by an Argo CD Application is a bug, and that is a query, not an opinion." This is the
# query. Without it, ADR-0002 Rule 1 - nothing in Layer 3 installed by hand - is a promise that
# nobody checks, which is how the last attempt at this platform ended up unable to answer "who
# owns this object?".
#
# Argo CD marks what it manages with an annotation (resourceTrackingMethod: annotation, chosen
# in ADR-0009 Decision 4). So drift is: a resource in a non-system namespace with no such
# annotation and no owner that has one.
set -uo pipefail

TRACK=argocd.argoproj.io/tracking-id

# Namespaces whose contents are legitimately NOT Argo CD's. These are Layers 0-2: the control
# plane, the CNI, and Argo CD itself. Adding to this list is how you hide drift from yourself,
# so each entry says why it is here.
declare -A SYSTEM_NS=(
  [kube-system]="Layer 1 - kubeadm's own components and the CNI (ADR-0008)"
  [kube-public]="created by kubeadm; holds the cluster-info ConfigMap"
  [kube-node-lease]="created by kubeadm; node heartbeats"
  [default]="created by Kubernetes; should stay empty"
  [argocd]="Layer 2 - the Argo CD Helm release itself (ADR-0002 Rule 2)"
  [cilium-secrets]="created by the Cilium chart, Layer 1"
  [kube-flannel]="not used here; listed so its presence is obviously wrong"
)

KINDS=(deployment statefulset daemonset service configmap secret serviceaccount ingress gateway httproute)

c_hdr=$'\033[36m'; c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

kubectl version --client >/dev/null 2>&1 || { echo "kubectl not available" >&2; exit 1; }
kubectl -n argocd get applications >/dev/null 2>&1 \
  || { echo "Argo CD is not installed - run: make onprem-argocd" >&2; exit 1; }

printf '%scontext%s %s\n\n' "$c_hdr" "$c_off" "$(kubectl config current-context)"

drift=0

printf '%s=== namespaces nobody claims ===%s\n' "$c_hdr" "$c_off"
while read -r ns; do
  [[ -n "${SYSTEM_NS[$ns]:-}" ]] && continue
  ann=$(kubectl get ns "$ns" -o "jsonpath={.metadata.annotations.${TRACK//./\\.}}" 2>/dev/null)
  if [[ -z "$ann" ]]; then
    printf '  %sDRIFT%s namespace/%s\n' "$c_bad" "$c_off" "$ns"
    drift=$((drift + 1))
  fi
done < <(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
[[ $drift -eq 0 ]] && printf '  %snone%s\n' "$c_ok" "$c_off"

printf '\n%s=== resources nobody claims (non-system namespaces) ===%s\n' "$c_hdr" "$c_off"
found=0
while read -r ns; do
  [[ -n "${SYSTEM_NS[$ns]:-}" ]] && continue
  for kind in "${KINDS[@]}"; do
    # Resource types that do not exist yet (gateway, httproute before Module 05) are skipped
    # silently rather than treated as an error.
    while read -r name ann; do
      [[ -z "$name" ]] && continue
      # A default ServiceAccount and its token are created by Kubernetes in every namespace.
      [[ "$kind" == "serviceaccount" && "$name" == "default" ]] && continue
      [[ "$kind" == "configmap" && "$name" == "kube-root-ca.crt" ]] && continue
      if [[ "$ann" == "<none>" || -z "$ann" ]]; then
        printf '  %sDRIFT%s %s/%s %sin %s%s\n' "$c_bad" "$c_off" "$kind" "$name" "$c_dim" "$ns" "$c_off"
        found=$((found + 1))
      fi
    done < <(kubectl -n "$ns" get "$kind" \
               -o "custom-columns=NAME:.metadata.name,OWNER:.metadata.annotations.${TRACK//./\\.}" \
               --no-headers 2>/dev/null)
  done
done < <(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
[[ $found -eq 0 ]] && printf '  %snone%s\n' "$c_ok" "$c_off"
drift=$((drift + found))

printf '\n%s=== the seam: what Ansible is allowed to own ===%s\n' "$c_hdr" "$c_off"
printf '  %s\n' "the Argo CD Helm release, plus exactly these files (ADR-0009):"
ls -1 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitops/bootstrap/" | sed 's/^/    gitops\/bootstrap\//'

echo
if [[ $drift -eq 0 ]]; then
  printf '%sNo drift. Everything outside the system namespaces is owned by an Application.%s\n' "$c_ok" "$c_off"
else
  printf '%s%d object(s) nobody claims.%s\n' "$c_bad" "$drift" "$c_off"
  cat <<'EOT'

  Each one is either:
    - something applied by hand that should be in Git  -> add it, then delete it from the
      cluster and let Argo CD recreate it, so that Git is the source rather than a copy;
    - a legitimate Layer 0-2 component                 -> add its namespace to SYSTEM_NS in
      this script, WITH the reason, so the exemption is recorded rather than assumed;
    - a leftover from debugging                        -> delete it.

  "I will tidy that up later" is how the previous attempt reached a cluster nobody could
  describe. ADR-0002 Rule 1 allows deliberate, documented debugging - reverted immediately.
EOT
  exit 1
fi
