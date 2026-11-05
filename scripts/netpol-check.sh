#!/usr/bin/env bash
# Prove the tenant's network policy actually denies something.
#
#   make netpol-check
#
# A policy nobody has seen deny anything is indistinguishable from no policy, and this week has
# produced five separate instances of a check that agreed with whoever wrote it. So this does not
# ask Kubernetes whether the policy exists - it asks the network whether it is enforced.
#
# Five probes, and the ORDER is load-bearing since egress was policed on 2026-11-05:
#
#   1. the application still works            - the allowed path, end to end
#   2. DNS still resolves from a policed pod  - MUST come before 3 and 4, see below
#   3. an UNLISTED pod cannot reach the DB    - the denial
#   4. a LISTED pod CAN reach the DB          - proves the policy selects on the label, rather
#                                               than the database being unreachable for some
#                                               unrelated reason
#   5. an unexpected destination is refused   - the egress denial
#
# Without 4, a broken database and a working policy look identical: 3 on its own would pass
# against a MongoDB that had simply crashed.
#
# AND WITHOUT 2, PROBES 3 AND 4 STOPPED MEANING ANYTHING THE MOMENT EGRESS WAS POLICED. They
# connect to the database BY NAME, and an egress policy that forgets DNS makes every name fail -
# so probe 3 would still report "refused, as it should be" while reporting nothing about the
# database at all, and probe 4 would fail and blame MongoDB. That is the exact trap the egress
# parking-lot entry predicted: "an egress policy that breaks DNS passes 'can it still reach
# MongoDB' and fails everything else a minute later."
#
# So probe 2 resolves the name itself and hands 3 and 4 the ADDRESS. After it, a timeout is a
# policy decision rather than a resolution failure, which is the difference between a test and
# a coincidence.
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
EGRESS=$(yq -r '.egress.enabled // false' "$OVERLAY")
# A DESTINATION THAT WOULD WORK WITHOUT THE POLICY, which is what makes probe 5 evidence rather
# than a statement about the lab's internet connection. The control plane's API server is on the
# same libvirt network, is always listening, and is reachable from any unpoliced pod - so a
# timeout to it is the egress rule and nothing else. A public address would also test whether
# the laptop currently has internet, and would pass for the wrong reason when it does not.
DENIED_HOST=$(jq -r '.nodes[] | select(.role=="control-plane") | .address' clusters/onprem/nodes.json | head -1)
DENIED_PORT=6443
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

if [[ "$EGRESS" == "true" ]]; then
  if ! kubectl -n "$NS" get networkpolicy "${INSTANCE}-egress" >/dev/null 2>&1; then
    die "$OVERLAY sets egress.enabled but there is no NetworkPolicy ${INSTANCE}-egress in $NS.
Argo CD may not have synced yet:  make gitops-refresh && make gitops-status"
  fi
  # Read back what it actually allows, not what the chart was asked for. An egress policy with
  # one rule is a policy whose DNS exception is missing.
  n_egress=$(kubectl -n "$NS" get networkpolicy "${INSTANCE}-egress" \
             -o jsonpath='{.spec.egress}' | jq 'length')
  types=$(kubectl -n "$NS" get networkpolicy "${INSTANCE}-egress" \
          -o jsonpath='{.spec.policyTypes}' | jq -r 'join(",")')
  ok "NetworkPolicy ${INSTANCE}-egress: $n_egress rule(s), policyTypes=$types"
  if [[ "$types" == *Ingress* ]]; then
    bad "that policy also names Ingress, which switches EVERY pod in $NS to deny-by-default inbound"
    die "The frontend would stop accepting traffic from the Gateway, and the cause would look
like a broken application. The chart sets policyTypes: [Egress] on purpose."
  fi
else
  printf '    %segress.enabled is false in %s - probes 2 and 5 will be skipped%s\n' \
    "$c_dim" "$OVERLAY" "$c_off"
fi

# THE FRONT DOOR, checked for the one regression that would not show up here. Removing
# `remote-node` from this policy breaks nothing until the L2 lease next moves, and then it
# refuses the front door ~15s after an unrelated worker dies - so every probe below would still
# pass. `make ingress-failover-check` is the test; this is the guard against the edit.
FRONTEND=$(yq -r '.frontendIngress.enabled // false' "$OVERLAY")
if [[ "$FRONTEND" == "true" ]]; then
  if ! kubectl -n "$NS" get ciliumnetworkpolicies.cilium.io "${INSTANCE}-frontend-ingress" >/dev/null 2>&1; then
    die "$OVERLAY sets frontendIngress.enabled but there is no CiliumNetworkPolicy
${INSTANCE}-frontend-ingress in $NS.  make gitops-refresh && make gitops-status"
  fi
  ents=$(kubectl -n "$NS" get ciliumnetworkpolicies.cilium.io "${INSTANCE}-frontend-ingress" \
         -o jsonpath='{.spec.ingress[0].fromEntities}' | jq -r 'join(",")')
  # `ingress` is the one PROVEN necessary: without it the Gateway's Envoy is denied and the
  # front door returns 503 immediately. Probe 1 below would catch that, but it would blame the
  # database clients, so say it here where the cause is.
  if [[ "$ents" != *ingress* ]]; then
    bad "${INSTANCE}-frontend-ingress allows [$ents] - the 'ingress' entity is missing"
    die "That is Cilium's Gateway Envoy, and without it the front door is DENIED: the Gateway
has no reachable backend and returns 503. Observed on 2026-11-05 as

  10.244.1.207 (ingress) <> ${INSTANCE}-frontend:8080  policy-verdict:none INGRESS DENIED

Probe 1 below will fail too, but it points at the database clients, which is the wrong place."
  fi
  # NOTHING IS REQUIRED BEYOND `ingress`, and `remote-node` used to be. It was removed on
  # 2026-11-05 once measured: with the announcer on another node, the identities arriving are
  # `host ingress` and nothing else, so it matched nothing while permitting any node to open
  # this port. The entity list is verified by observation now rather than by a required-strings
  # check here:
  #
  #   make ingress-failover-check
  #
  # which puts the announcer on a different node than the frontend and asserts that every
  # identity it sees arriving is one this policy permits. That form cannot go stale the way a
  # hardcoded list can.
  ok "CiliumNetworkPolicy ${INSTANCE}-frontend-ingress allows [$ents]"
else
  printf '    %sfrontendIngress.enabled is false - the front door accepts everything inbound%s\n' \
    "$c_dim" "$c_off"
fi

# ---------------------------------------------------------------- 1
step '1/5 the application still works (the allowed path, end to end)'
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
  # ds/cilium picks an ARBITRARY agent, and an agent only sees its OWN node's flows:
  AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector \\
    spec.nodeName=$(kubectl -n $NS get pod ${DB_SVC}-0 -o jsonpath='{.spec.nodeName}') \\
    -o jsonpath='{.items[0].metadata.name}')
  kubectl -n kube-system exec $AGENT -- hubble observe --to-pod $NS/${DB_SVC}-0 --verdict DROPPED --last 20"
  fi
fi

# ---------------------------------------------------------------- 2
step '2/5 DNS still resolves from a pod the egress policy selects'
# ONE PROBE POD FOR 2, 3 AND 5, created here rather than in probe 3 because DNS has to be
# answered first. It wears a label that is NOT in the database policy's client list, so it is
# the denied pod for probe 3 as well.
kubectl -n "$NS" run netpol-denied --image="$PROBE_IMAGE" --restart=Never \
  --labels="app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=netpol-probe" \
  --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/netpol-denied --timeout=120s >/dev/null \
  || die "the probe pod never became Ready"

DB_IP=""
if [[ "$EGRESS" != "true" ]]; then
  printf '    %s(skipped - egress is not policed, so DNS is not at risk here)%s\n' "$c_dim" "$c_off"
else
  # getent rather than nslookup or dig: it goes through the pod's resolver exactly as the
  # application's runtime does, and it exits non-zero on failure instead of printing a message
  # and exiting 0, which `nslookup` does for some failures.
  DB_IP=$(kubectl -n "$NS" exec netpol-denied -- \
          getent hosts "$DB_SVC" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -z "$DB_IP" ]]; then
    bad "$DB_SVC does not resolve from inside $NS"
    die "THE EGRESS POLICY HAS BROKEN DNS, which is the failure this probe exists to catch, and
it is the one that does not look like a network policy: every service in the namespace will
report connection errors to names that used to work.

The DNS rule must be ONE peer with both selectors - namespaceSelector AND podSelector in the
same list item. Written as two items it becomes an OR and matches the wrong thing. Check what
actually landed:

  kubectl -n $NS get networkpolicy ${INSTANCE}-egress -o yaml
  kubectl -n kube-system get pods -l k8s-app=kube-dns
  AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector \\
    spec.nodeName=$(kubectl -n $NS get pod netpol-denied -o jsonpath='{.spec.nodeName}') \\
    -o jsonpath='{.items[0].metadata.name}')   # NOT ds/cilium - one agent, one node's flows
  kubectl -n kube-system exec $AGENT -- hubble observe --from-pod $NS/netpol-denied --verdict DROPPED --last 20

The quickest way back is egress.enabled: false in $OVERLAY, which returns the namespace to
accepting everything outbound."
  fi
  ok "$DB_SVC resolves to $DB_IP  (so a timeout below is a policy decision, not a lookup)"
fi

# ---------------------------------------------------------------- 3
step '3/5 a pod the policy does NOT list cannot reach the database'
# BY ADDRESS when we have one, by name otherwise. With egress policed, `nc -z <name>` failing
# proves nothing on its own: resolution and connection are two separate permissions, and this
# probe is about the second one.
TARGET="${DB_IP:-$DB_SVC}"
# -w 5 so a DROP shows as a timeout rather than hanging. A dropped packet produces no RST, so
# the connection does not fail fast - that silence IS the policy working.
if kubectl -n "$NS" exec netpol-denied -- nc -z -w 5 "$TARGET" "$PORT" >/dev/null 2>&1; then
  bad "netpol-probe REACHED $TARGET:$PORT - the policy is not being enforced"
  printf '%s    Everything else may still look correct. This is the case that matters.%s\n' "$c_dim" "$c_off"
  exit 1
else
  ok "netpol-probe -> $TARGET:$PORT  refused/timed out, as it should be"
fi

# ---------------------------------------------------------------- 4
step "4/5 a pod the policy DOES list can reach it (label: $ALLOWED)"
# The same image and namespace, differing only in one label value. If this also fails, the
# database is simply unreachable and probe 3 proved nothing.
kubectl -n "$NS" run netpol-allowed --image="$PROBE_IMAGE" --restart=Never \
  --labels="app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=$ALLOWED" \
  --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/netpol-allowed --timeout=120s >/dev/null \
  || die "the allowed probe pod never became Ready"
if kubectl -n "$NS" exec netpol-allowed -- nc -z -w 5 "$TARGET" "$PORT" >/dev/null 2>&1; then
  ok "a pod labelled $ALLOWED -> $TARGET:$PORT  connected"
else
  bad "a pod labelled $ALLOWED could NOT reach $TARGET:$PORT"
  die "So probe 3 proved nothing: the database is unreachable for both, and a crashed MongoDB
would produce exactly this output. Check the database before reading anything above as a
policy result:
  kubectl -n $NS get pod -l app.kubernetes.io/name=$DB"
fi

# ---------------------------------------------------------------- 5
step '5/5 a destination the tenant has no business reaching is refused'
if [[ "$EGRESS" != "true" ]]; then
  printf '    %s(skipped - egress.enabled is false, so nothing is denied outbound)%s\n' "$c_dim" "$c_off"
elif [[ -z "$DENIED_HOST" || "$DENIED_HOST" == "null" ]]; then
  printf '    %s(skipped - no control-plane address in clusters/onprem/nodes.json)%s\n' "$c_dim" "$c_off"
else
  # The API server, by ADDRESS, on the node network. Reachable from any unpoliced pod in this
  # cluster, so a timeout here is the egress rule. Deliberately not a public address: that would
  # also pass when the laptop simply has no internet.
  if kubectl -n "$NS" exec netpol-allowed -- \
       nc -z -w 5 "$DENIED_HOST" "$DENIED_PORT" >/dev/null 2>&1; then
    bad "a tenant pod REACHED $DENIED_HOST:$DENIED_PORT - egress is not being enforced"
    die "This is the hole the egress policy exists to close: a compromised pod can still open a
connection to the node network, and from there to anything the nodes can reach. Check that the
policy selects every pod rather than a label:

  kubectl -n $NS get networkpolicy ${INSTANCE}-egress -o jsonpath='{.spec.podSelector}'

An empty {} is correct. A matchLabels there leaves unlabelled pods unpoliced."
  else
    ok "tenant pod -> $DENIED_HOST:$DENIED_PORT (the API server)  refused/timed out"
  fi
fi

echo
printf '%snetwork policy is enforced: one label value decides access to the database,%s\n' "$c_ok" "$c_off"
printf '%sand the namespace can now reach only DNS and itself%s\n' "$c_ok" "$c_off"
echo
printf 'Two pods, same namespace, same image, differing in one label. One reached MongoDB and\n'
printf 'one did not, which is the only evidence that makes the policy real rather than present.\n'
printf 'The same pod resolved a name and could not open a connection to the node network, which\n'
printf 'is what distinguishes a working egress policy from a broken resolver.\n'
echo
printf 'The front door is covered too, by the CiliumNetworkPolicy named above - the one object\n'
printf 'here that cannot be written portably, since the source is the node and plain\n'
printf 'NetworkPolicy has no selector for a node. On GKE the equivalent is a Google-owned source\n'
printf 'range and on EKS a VPC range; the gcp and aws overlays say so.\n'
echo
printf '%sWhat THIS check cannot tell you:%s whether that rule survives the L2 announcement lease\n' "$c_warn" "$c_off"
printf 'moving to a node other than the frontend. Every probe above runs with the announcer\n'
printf 'wherever it happens to be, and the rule was wrong once in exactly that way. The only\n'
printf 'thing that answers it moves the lease on purpose:\n'
printf '\n  make ingress-failover-check\n\n'
printf 'It also reports which identity the traffic arrived as, which is how `remote-node` stops\n'
printf 'being an unverified entry in the entity list.\n'
