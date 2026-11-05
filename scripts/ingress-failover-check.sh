#!/usr/bin/env bash
# Move the L2 announcement lease on purpose, and prove the front door still opens.
#
#   make ingress-failover-check
#
# THIS POWERS OFF A WORKER. Not a graceful shutdown - `virsh destroy`, which is the virtual
# equivalent of pulling the plug, because a graceful shutdown lets Kubernetes drain the node and
# hand the lease over tidily, and the failure worth testing is the one where nothing got to say
# goodbye.
#
# WHY IT EXISTS. `shopverse-frontend-ingress` is a CiliumNetworkPolicy allowing
# `fromEntities: [host, remote-node]`. The `host` half is easy and is also a trap: Cilium's
# allow-localhost default permits the local node anyway, so a rule listing only `host` passes
# every test you can run while the L2 lease happens to sit on the frontend's own node.
#
# The lease MOVES. ADR-0013 measured ~15s for a hard power-off, and from that moment the Envoy
# proxying into the frontend is on a different node and arrives as `remote-node`. A policy
# without that entity starts refusing the front door fifteen seconds after an unrelated node
# died, with nothing in the application changed - which is why the parking-lot entry for this
# rule said to verify it by moving the lease rather than by curling once: "a rule that is
# correct until a failover is worse than no rule, because it gets trusted."
#
# What this measures, and what it does not: it measures whether the front door reopens, and how
# long that took. It does not prove the 15s figure - the number varies with the lease timings in
# cilium-values.yaml, and ADR-0013 explains why they are left at their defaults.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OVERLAY=gitops/environments/onprem/tenant-network-policies.yaml
CA=.cache/platform-ca.crt
V="virsh -c qemu:///system"

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
info() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

for t in kubectl jq yq curl virsh; do
  command -v "$t" >/dev/null || die "$t is not installed - run: make tools"
done

NS=$(yq -r '.tenant.namespace' "$OVERLAY")
INSTANCE=$(yq -r '.tenant.instance' "$OVERLAY")
FE=$(yq -r '.frontendIngress.name // "frontend"' "$OVERLAY")
[[ -n "$NS" && "$NS" != "null" ]] || die "no tenant.namespace in $OVERLAY"
HOST=$(jq -r '.loadbalancer.gateway_hostnames[]? | select(test("shopverse"))' clusters/onprem/nodes.json | head -1)
[[ -n "$HOST" ]] || die "no shopverse gateway hostname in clusters/onprem/nodes.json"
[[ -f "$CA" ]] || die "$CA is missing - run: make onprem-ca"

probe() { curl -sS -o /dev/null -m 5 -w '%{http_code}' --cacert "$CA" "https://$HOST/" 2>/dev/null || echo 000; }

lease_holder() {
  kubectl get leases -n kube-system -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name | test("cilium-l2announce")) | .spec.holderIdentity' 2>/dev/null \
    | head -1
}

printf '%sIngress failover check: does the front door survive the lease moving?%s\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0
step 'the policy that makes this interesting'
if ! kubectl -n "$NS" get ciliumnetworkpolicies.cilium.io "${INSTANCE}-frontend-ingress" >/dev/null 2>&1; then
  die "no CiliumNetworkPolicy ${INSTANCE}-frontend-ingress in $NS.
Either it has not synced (make gitops-refresh && make gitops-status) or
frontendIngress.enabled is false in $OVERLAY - in which case the frontend
accepts everything inbound and there is nothing for this test to prove."
fi
ents=$(kubectl -n "$NS" get ciliumnetworkpolicies.cilium.io "${INSTANCE}-frontend-ingress" \
       -o jsonpath='{.spec.ingress[0].fromEntities}' | jq -r 'join(", ")')
ok "fromEntities: $ents"
if [[ "$ents" != *remote-node* ]]; then
  bad "remote-node is NOT in that list"
  info "This test is about to demonstrate the bug rather than the fix: once the lease moves to a"
  info "node that is not the frontend's, the front door will stop answering and stay shut."
  info "That is worth seeing once. Carry on if that is what you meant."
fi

# ---------------------------------------------------------------- 1
step '1/3 the front door answers now'
code=$(probe)
[[ "$code" == 200 ]] || die "GET https://$HOST/ -> $code before touching anything.
Fix that first; this test can only tell you something if it starts from a working front door."
ok "GET https://$HOST/ -> 200"

HOLDER=$(lease_holder)
[[ -n "$HOLDER" && "$HOLDER" != "null" ]] || die "no cilium-l2announce lease found - is the
CiliumL2AnnouncementPolicy synced?  kubectl get ciliuml2announcementpolicies.cilium.io"
FE_NODE=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=$FE" \
          -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
ok "the lease is held by $HOLDER; the frontend runs on ${FE_NODE:-unknown}"

# THE CONTROL PLANE IS NOT A CANDIDATE. Powering it off takes etcd and the API server with it,
# which is a different experiment (Module 11) and would make everything below unreadable.
ROLE=$(kubectl get node "$HOLDER" -o jsonpath='{.metadata.labels}' 2>/dev/null \
       | jq -r 'if has("node-role.kubernetes.io/control-plane") then "control-plane" else "worker" end')
if [[ "$ROLE" == "control-plane" ]]; then
  die "the lease is held by the CONTROL PLANE ($HOLDER), and this script will not power that off:
losing it takes etcd and the API server, which is Module 11's experiment and not this one.

Wait for the lease to move, or move it by restarting the Cilium agent there:
  kubectl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=$HOLDER"
fi

# TWO QUESTIONS, AND THE THIRD VERSION OF THIS SCRIPT IS THE ONE THAT SEPARATES THEM.
#
#   Q1  does the policy permit the front door when the announcer is NOT the frontend's node?
#       That is the failure the rule exists to prevent. It needs no outage at all: produce the
#       state, send a request, and read the identity Cilium saw.
#
#   Q2  does the front door come back when the announcing node DIES?
#       A different question - about recovery, not about the policy.
#
# Run 1 destroyed the frontend's own node and could not tell a denial from a pod that had not
# restarted. Run 2 did better and still failed for a reason that was not a failure: with two
# workers, powering off the announcer leaves exactly one candidate, so the lease MUST land on
# the frontend's node afterwards. The script called that "cannot test remote-node" and exited 1
# - while its own step 1 had already answered Q1 in the affirmative and thrown the answer away.
#
# So Q1 is now the default and is non-destructive. Q2 is opt-in, and co-location afterwards is
# reported rather than treated as a failure, because on a two-worker cluster it is the only
# possible outcome.
if [[ "$HOLDER" == "$FE_NODE" ]]; then
  step "2/3 moving the lease off $HOLDER so the front door has to cross nodes"
  info "both are on $HOLDER, so traffic currently arrives as 'host' - exactly the state in"
  info "which a rule missing the cross-node entity looks fine. Restarting its Cilium agent:"
  info "the lease expires, a survivor takes it, and the frontend does not move."
  kubectl -n kube-system delete pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$HOLDER" >/dev/null \
    || die "could not restart the Cilium agent on $HOLDER"
  for _ in $(seq 1 45); do
    cur=$(lease_holder)
    if [[ -n "$cur" && "$cur" != "null" && "$cur" != "$HOLDER" ]]; then HOLDER="$cur"; break; fi
    sleep 2
  done
  if [[ "$HOLDER" == "$FE_NODE" ]]; then
    die "the lease did not move off $FE_NODE within 90s. With one other worker it may have
nowhere to go, or the announcement policy may select a single node:
  kubectl get ciliuml2announcementpolicies.cilium.io -o yaml
  kubectl get leases -n kube-system | grep l2announce"
  fi
  ok "lease moved to $HOLDER, which is not the frontend's node"
else
  step '2/3 the announcer is already on another node'
  ok "announcer $HOLDER, frontend $FE_NODE - nothing to move"
fi

# ---------------------------------------------------------------- 3
step '3/3 the front door, across nodes, and the identity it arrives as'
code=$(probe)
if [[ "$code" != 200 ]]; then
  bad "GET https://$HOST/ -> $code with the announcer on $HOLDER and the frontend on $FE_NODE"
  printf '\n%sTHIS IS THE FINDING, and it is unambiguous: nothing was powered off, the frontend%s\n' "$c_err" "$c_off"
  printf 'never moved, only the announcer changed - and the front door is shut. The rule is\n'
  printf 'missing whatever identity cross-node ingress arrives as. Read it:\n\n'
  printf '  AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector \\\n'
  printf '    spec.nodeName=%s -o jsonpath=\x27{.items[0].metadata.name}\x27)\n' "$FE_NODE"
  printf '  kubectl -n kube-system exec $AGENT -- hubble observe \\\n'
  printf '    --to-label app.kubernetes.io/name=%s --verdict DROPPED --last 20\n' "$FE"
  exit 1
fi
ok "GET https://$HOST/ -> 200  with announcer and backend on DIFFERENT nodes"
info "that is Q1 answered: the rule permits the front door when the lease is elsewhere, which"
info "is the exact case the [host]-only version would have refused."

# WHICH IDENTITY, because the 200 does not say. `remote-node` has been carried in fromEntities
# as an unverified hedge since the rule was written, and this is what settles it.
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
        --field-selector "spec.nodeName=$FE_NODE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$AGENT" ]]; then
  info "no Cilium agent on $FE_NODE - cannot read the identity"
else
  probe >/dev/null; sleep 2
  flows=$(kubectl -n kube-system exec "$AGENT" -- hubble observe \
          --to-label "app.kubernetes.io/name=$FE" --last 30 2>/dev/null \
          | grep -oE '\((ingress|host|remote-node|world|unmanaged)\)' | sort -u | tr -d '()' | tr '\n' ' ')
  if [[ -z "$flows" ]]; then
    info "the agent on $FE_NODE reported no flows - the ring buffer may have rotated"
  else
    ok "identities arriving at the frontend: $flows"
    if [[ "$flows" == *remote-node* ]]; then
      ok "remote-node IS exercised - that entity is load-bearing, not a hedge"
    else
      info "remote-node did NOT appear even with the announcer on another node, so Cilium's"
      info "ingress proxy keeps its own identity wherever it runs. The entity is harmless, and"
      info "this run is the first evidence that it may be unnecessary - recorded rather than"
      info "acted on, because one observation is where today's wrong answers came from."
    fi
  fi
fi

# ---------------------------------------------------------------- Q2, opt-in
if [[ "${CONFIRM:-}" != "yes" ]]; then
  echo
  printf '%sthe front door works across nodes: announcer %s, frontend %s%s\n' "$c_ok" "$HOLDER" "$FE_NODE" "$c_off"
  echo
  printf 'That is the question the rule exists to answer, and nothing was powered off to answer\n'
  printf 'it. A rule correct only while the lease sat on the right node would have passed every\n'
  printf 'other test in this repository and failed here.\n'
  echo
  printf '%sNot tested:%s whether the front door RECOVERS when the announcing node dies, which is\n' "$c_warn" "$c_off"
  printf 'a question about recovery rather than about the policy. It powers off a worker:\n'
  printf '\n  make ingress-failover-check CONFIRM=yes\n\n'
  printf 'On a two-worker cluster the lease must then land on the node the frontend runs on, so\n'
printf 'that run measures how long the door stays shut, not whether it crosses nodes.\n'
    exit 0
fi

step "powering off the announcer $HOLDER (hard, no graceful shutdown)"
if [[ "$HOLDER" == "$FE_NODE" ]]; then
  die "refusing: $HOLDER is also the frontend's node, so this would reschedule the backend and
a 503 would be indistinguishable from a policy denial. That is how run 1 of this script wasted
a node restart. Re-run without CONFIRM=yes to move the lease instead."
fi
ROLE=$(kubectl get node "$HOLDER" -o jsonpath='{.metadata.labels}' 2>/dev/null \
       | jq -r 'if has("node-role.kubernetes.io/control-plane") then "control-plane" else "worker" end')
[[ "$ROLE" == "worker" ]] || die "refusing: $HOLDER is the control plane, and losing etcd is
Module 11's experiment rather than this one."
$V destroy "$HOLDER" >/dev/null 2>&1 || die "virsh destroy $HOLDER failed - $V list --all"
ok "$HOLDER is off"
restore() {
  printf '\n%s==> restoring %s%s\n' "$c_step" "$HOLDER" "$c_off"
  $V start "$HOLDER" >/dev/null 2>&1 || bad "could not start $HOLDER - do it by hand: $V start $HOLDER"
  for _ in $(seq 1 60); do
    [[ "$(kubectl get node "$HOLDER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]] \
      && { ok "$HOLDER is Ready again"; return; }
    sleep 5
  done
  bad "$HOLDER did not become Ready within 5 minutes - check it before trusting the cluster"
}
trap restore EXIT

step 'how long the front door stays shut'
start=$SECONDS
recovered=""
for _ in $(seq 1 90); do
  [[ "$(probe)" == 200 ]] && { recovered=$((SECONDS - start)); break; }
  sleep 2
done
NEW=$(lease_holder)
if [[ -z "$recovered" ]]; then
  bad "the front door did not reopen within ~180s; the lease now reads ${NEW:-unknown}"
  die "The frontend did not move (it is on $FE_NODE, which is up), so this is about the
announcer: either the lease never moved or the new announcer cannot serve the address."
fi
ok "reopened after ${recovered}s; lease $HOLDER -> ${NEW:-unknown}"
[[ "$NEW" == "$FE_NODE" ]] && info "and the lease landed on the frontend's node, which on a
    two-worker cluster is the only place left - so this number is recovery time, not a
    cross-node result. The cross-node result is the phase above."

echo
printf '%sthe front door recovered from losing its announcer in %ss%s\n' "$c_ok" "$recovered" "$c_off"
