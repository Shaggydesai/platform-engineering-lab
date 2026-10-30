#!/usr/bin/env bash
# Prove the tenant's network policy actually denies something.
#
#   make netpol-check
#
# A policy nobody has seen deny anything is indistinguishable from no policy, and this week has
# produced five separate instances of a check that agreed with whoever wrote it. So this does not
# ask Kubernetes whether the policy exists - it asks the network whether it is enforced.
#
# Three probes, and the third is the one that makes the other two mean anything:
#
#   1. the application still works            - the allowed path, end to end
#   2. an UNLISTED pod cannot reach the DB    - the denial
#   3. a LISTED pod CAN reach the DB          - proves the policy selects on the label, rather
#                                               than the database being unreachable for some
#                                               unrelated reason
#
# Without 3, a broken database and a working policy look identical. That distinction is the whole
# test; 2 on its own would pass against a MongoDB that had simply crashed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OVERLAY=gitops/environments/onprem/tenant-network-policies.yaml
CA=.cache/platform-ca.crt
PROBE_IMAGE=nicolaka/netshoot

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"
command -v yq >/dev/null || die "yq not installed - run: make tools"

NS=$(yq -r '.tenant.namespace' "$OVERLAY")
INSTANCE=$(yq -r '.tenant.instance' "$OVERLAY")
DB=$(yq -r '.database.name' "$OVERLAY")
PORT=$(yq -r '.database.port' "$OVERLAY")
ALLOWED=$(yq -r '.database.clients[0]' "$OVERLAY")
HOST=$(jq -r '.loadbalancer.gateway_hostnames[]? | select(test("shopverse"))' clusters/onprem/nodes.json | head -1)

[[ -n "$NS" && "$NS" != "null" ]] || die "no tenant.namespace in $OVERLAY"
DB_SVC="${INSTANCE}-${DB}"

cleanup() { kubectl -n "$NS" delete pod netpol-denied netpol-allowed --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '%sNetwork policy enforcement check: %s/%s%s\n\n' "$c_step" "$NS" "$DB_SVC" "$c_off"

# ---------------------------------------------------------------- 0
step 'the policy object exists and selects the database'
if ! kubectl -n "$NS" get networkpolicy "${INSTANCE}-database" >/dev/null 2>&1; then
  die "no NetworkPolicy ${INSTANCE}-database in $NS.
Argo CD may not have synced yet:  make gitops-refresh && make gitops-status"
fi
sel=$(kubectl -n "$NS" get networkpolicy "${INSTANCE}-database" \
      -o jsonpath='{.spec.podSelector.matchLabels}')
ok "NetworkPolicy ${INSTANCE}-database selects $sel"
n_from=$(kubectl -n "$NS" get networkpolicy "${INSTANCE}-database" \
         -o jsonpath='{.spec.ingress[0].from}' | jq 'length')
ok "$n_from allowed client selector(s)"

# ---------------------------------------------------------------- 1
step '1/3 the application still works (the allowed path, end to end)'
if [[ -z "$HOST" || ! -f "$CA" ]]; then
  printf '    %s(skipped - no shopverse hostname or %s missing; run make onprem-ca)%s\n' \
    "$c_dim" "$CA" "$c_off"
else
  code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' --cacert "$CA" \
         "https://$HOST/api/products" 2>/dev/null || true)
  code=${code:-000}
  # /api/products reaches MongoDB through product-service, so a 200 here is the five allowed
  # clients working. A policy that broke them would show up as 502 or 000, not as a subtle bug.
  if [[ "$code" == 200 ]]; then
    ok "GET /api/products -> 200  (product-service is reaching the database)"
  else
    bad "GET /api/products -> $code"
    die "the policy appears to have broken the application - this is the failure mode worth
having a test for. Check which clients the overlay lists against what Hubble sees:
  kubectl -n kube-system exec ds/cilium -- hubble observe --to-pod $NS/${DB_SVC}-0 --verdict DROPPED --last 20"
  fi
fi

# ---------------------------------------------------------------- 2
step '2/3 a pod the policy does NOT list cannot reach the database'
kubectl -n "$NS" run netpol-denied --image="$PROBE_IMAGE" --restart=Never \
  --labels="app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=netpol-probe" \
  --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/netpol-denied --timeout=120s >/dev/null \
  || die "the probe pod never became Ready"
# -w 5 so a DROP shows as a timeout rather than hanging. A dropped packet produces no RST, so
# the connection does not fail fast - that silence IS the policy working.
if kubectl -n "$NS" exec netpol-denied -- nc -z -w 5 "$DB_SVC" "$PORT" >/dev/null 2>&1; then
  bad "netpol-probe REACHED $DB_SVC:$PORT - the policy is not being enforced"
  printf '%s    Everything else may still look correct. This is the case that matters.%s\n' "$c_dim" "$c_off"
  exit 1
else
  ok "netpol-probe -> $DB_SVC:$PORT  refused/timed out, as it should be"
fi

# ---------------------------------------------------------------- 3
step "3/3 a pod the policy DOES list can reach it (label: $ALLOWED)"
# The same image and namespace, differing only in one label value. If this also fails, the
# database is simply unreachable and probe 2 proved nothing.
kubectl -n "$NS" run netpol-allowed --image="$PROBE_IMAGE" --restart=Never \
  --labels="app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=$ALLOWED" \
  --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/netpol-allowed --timeout=120s >/dev/null \
  || die "the allowed probe pod never became Ready"
if kubectl -n "$NS" exec netpol-allowed -- nc -z -w 5 "$DB_SVC" "$PORT" >/dev/null 2>&1; then
  ok "a pod labelled $ALLOWED -> $DB_SVC:$PORT  connected"
else
  bad "a pod labelled $ALLOWED could NOT reach $DB_SVC:$PORT"
  die "So probe 2 proved nothing: the database is unreachable for both, and a crashed MongoDB
would produce exactly this output. Check the database before reading anything above as a
policy result:
  kubectl -n $NS get pod -l app.kubernetes.io/name=$DB"
fi

echo
printf '%snetwork policy is enforced: one label value decides access to the database%s\n' "$c_ok" "$c_off"
echo
printf 'Two pods, same namespace, same image, differing in one label. One reached MongoDB and\n'
printf 'one did not, which is the only evidence that makes the policy real rather than present.\n'
echo
printf '%sNot yet covered:%s egress is unrestricted, so a compromised pod can still call out; and\n' "$c_warn" "$c_off"
printf 'nothing yet restricts ingress to the frontend, because that traffic arrives from Cilium\n'
printf 'as reserved:host and plain NetworkPolicy cannot select it. See the gcp/aws overlays for\n'
printf 'why that rule is the one thing here that cannot be written portably.\n'
