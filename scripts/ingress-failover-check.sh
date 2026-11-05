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
step '1/4 the front door answers now'
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

# WHICH METHOD, and this is the fix for the first run of this script (2026-11-05), which
# destroyed the node the frontend was running on and produced a result that meant nothing.
#
# THE STATE WE WANT is "the announcer is not the frontend's node". Killing a node is one way to
# reach it and a poor one when that node is also the frontend's: the pod is then rescheduled and
# pulls its image elsewhere, so a 503 might be a policy denial or might be a pod that has not
# started, and the check cannot tell you which. That is the same ambiguity this repository has
# been removing all day, authored into a brand-new check by the person removing it.
#
# So: move the LEASE when they are co-located, and kill the NODE only when the frontend is
# somewhere else and the result stays readable.
if [[ "$HOLDER" == "$FE_NODE" ]]; then
  METHOD=lease
  info "the announcer and the frontend are both on $HOLDER, so traffic currently arrives as"
  info "'host' - which is exactly the state in which a rule missing remote-node looks fine."
  info "Powering this node off would also take the frontend, and a 503 would then be"
  info "indistinguishable from a pod that has not finished starting. Moving the lease instead."
else
  METHOD=node
  info "the frontend is on $FE_NODE and the announcer is $HOLDER - already different, so the 200"
  info "above already crosses nodes. Powering off the announcer adds the recovery half."
fi

# ---------------------------------------------------------------- 2
if [[ "$METHOD" == lease ]]; then
  step "2/4 moving the lease off $HOLDER by restarting its Cilium agent"
  # Non-destructive: the agent is back in seconds, and while it is gone the lease expires and a
  # surviving node takes it. Nothing else on the node is touched, so the frontend stays exactly
  # where it is - which is the entire point.
  kubectl -n kube-system delete pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$HOLDER" >/dev/null \
    || die "could not restart the Cilium agent on $HOLDER"
  ok "agent on $HOLDER restarted; waiting for the lease to move"
else
  step "2/4 powering off $HOLDER (hard, no graceful shutdown)"
  if [[ "${CONFIRM:-}" != "yes" ]]; then
    if [[ ! -t 0 ]]; then
      die "this powers off $HOLDER and needs confirmation. Re-run with:  make ingress-failover-check CONFIRM=yes"
    fi
    printf '    %sType the node name to confirm, anything else aborts: %s' "$c_warn" "$c_off"
    read -r answer
    [[ "$answer" == "$HOLDER" ]] || die "aborted - nothing was touched"
  fi
  $V destroy "$HOLDER" >/dev/null 2>&1 || die "virsh destroy $HOLDER failed - is the domain named
differently from the Kubernetes node?  $V list --all"
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
fi

# ---------------------------------------------------------------- 3
step '3/4 the lease moves, and then the front door'
# THE LEASE FIRST, SEPARATELY. If the front door is timed before the announcer has actually
# changed, the number measures lease expiry and not the policy - and if the lease never moves,
# a 503 says nothing at all.
NEW=""
for _ in $(seq 1 45); do
  cur=$(lease_holder)
  if [[ -n "$cur" && "$cur" != "null" && "$cur" != "$HOLDER" ]]; then NEW="$cur"; break; fi
  sleep 2
done
if [[ -z "$NEW" ]]; then
  bad "the lease still reads $(lease_holder) after 90s - it never moved"
  die "So nothing below could have told you anything about the policy. With only one other
candidate node the lease may have nowhere to go, or the L2 announcement policy may select a
single node:
  kubectl get ciliuml2announcementpolicies.cilium.io -o yaml
  kubectl get leases -n kube-system | grep l2announce"
fi
ok "lease moved: $HOLDER -> $NEW"
if [[ "$NEW" == "$FE_NODE" ]]; then
  bad "but $NEW is the FRONTEND's node, so traffic is arriving as 'host' again"
  die "This round cannot test remote-node: the announcer and the backend are co-located again,
which is the state the rule already worked in. Re-run - the lease lands somewhere else often
enough - or add a third worker so there is always a non-frontend candidate."
fi
ok "and $NEW is NOT the frontend's node, so the front door is now crossing nodes"

start=$SECONDS
recovered=""
for _ in $(seq 1 60); do
  code=$(probe)
  if [[ "$code" == 200 ]]; then recovered=$((SECONDS - start)); break; fi
  sleep 2
done
if [[ -z "$recovered" ]]; then
  bad "the front door did not reopen within ~120s (last response: $code)"
  printf '\n%sTHIS IS THE FINDING, and it is now unambiguous: the frontend never moved, the%s\n' "$c_err" "$c_off"
  printf 'announcer did, and the front door is shut. Read the identity Cilium is dropping:\n\n'
  printf '  AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector \\\n'
  printf '    spec.nodeName=%s -o jsonpath=\x27{.items[0].metadata.name}\x27)\n' "$FE_NODE"
  printf '  kubectl -n kube-system exec $AGENT -- hubble observe \\\n'
  printf '    --to-label app.kubernetes.io/name=%s --verdict DROPPED --last 20\n\n' "$FE"
  printf 'Whatever identity that names is what fromEntities is missing.\n'
  exit 1
fi
ok "front door reopened after ${recovered}s"

# ---------------------------------------------------------------- 4
step '4/4 which identity did that 200 actually arrive as?'
# THE QUESTION THE CURL CANNOT ANSWER. A 200 proves the policy permitted the traffic; it does
# not say which entity did the permitting, and `remote-node` has been carried in the rule as an
# unverified hedge since it was written. If this says `ingress` even across nodes, then Cilium's
# ingress proxy keeps its own identity wherever it runs and remote-node is dead weight - which
# is worth knowing rather than guessing.
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
        --field-selector "spec.nodeName=$FE_NODE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$AGENT" ]]; then
  info "no Cilium agent found on $FE_NODE - cannot read the identity"
else
  probe >/dev/null
  sleep 2
  flows=$(kubectl -n kube-system exec "$AGENT" -- hubble observe \
          --to-label "app.kubernetes.io/name=$FE" --last 20 2>/dev/null \
          | grep -oE '\((ingress|host|remote-node|world|unmanaged)\)' | sort -u | tr -d '()' | tr '\n' ' ')
  if [[ -z "$flows" ]]; then
    info "the agent on $FE_NODE reported no flows to the frontend - the ring buffer may have"
    info "rotated, or the request was served by an Envoy on another node's agent."
  else
    ok "identities seen arriving at the frontend: $flows"
    if [[ "$flows" == *remote-node* ]]; then
      ok "remote-node IS exercised - carrying it in fromEntities is load-bearing, not a hedge"
    else
      info "remote-node did NOT appear even with the announcer on another node, so Cilium's"
      info "ingress proxy keeps its own identity wherever it runs. The entity is harmless and"
      info "is no longer evidence-free: this run is the evidence that it may be unnecessary."
    fi
  fi
fi

echo
printf '%sthe front door survived the announcer moving to another node, in %ss%s\n' "$c_ok" "$recovered" "$c_off"
echo
printf 'That is the difference between this rule and the version listing only `host`: traffic\n'
printf 'now enters from a node other than the one the frontend runs on, and the policy still\n'
printf 'permits it. A rule correct only while the lease sat on the right node would have passed\n'
printf 'every other test in this repository and failed here.\n'
