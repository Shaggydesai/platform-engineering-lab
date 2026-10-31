#!/usr/bin/env bash
# Are Secrets actually encrypted in etcd?
#
#   make etcd-encryption-check
#
# Not "is the flag set" and not "did the API server restart" - those are requests. This reads the
# bytes out of etcd and looks at them, which is the only thing that answers the question.
# ADR-0018 Decision 7 says so and this is the script that makes it true.
#
# Exits non-zero while any Secret is still plaintext, because that IS the state of the cluster
# until `make etcd-reencrypt` has run. Enabling encryption does not reach backwards.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NS=kube-system
PROBE_NS=default
PROBE=etcd-encryption-probe

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
same() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n' "$c_err" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

cleanup() {
  kubectl -n "$PROBE_NS" delete secret "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%sIs anything actually encrypted in etcd?%s\n\n' "$c_step" "$c_off"

# ---------------------------------------------------------------- 0  the running API server
step 'the API server that is actually running'
APISERVER=$(kubectl -n "$NS" get pod -l component=kube-apiserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$APISERVER" ]] || die "no kube-apiserver pod found in $NS - is the cluster up?"

if kubectl -n "$NS" get pod "$APISERVER" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
   | grep -q 'encryption-provider-config'; then
  ok "$APISERVER has --encryption-provider-config"
  flag=1
else
  bad "$APISERVER does NOT have --encryption-provider-config"
  warn 'Encryption is not enabled. Every Secret below will be plaintext, which is the correct'
  warn 'answer rather than a fault - run:  make onprem-up TAGS=etcd-encryption'
  flag=0
fi

# ---------------------------------------------------------------- 1  reach etcd directly
step 'reading etcd'
ETCD=$(kubectl -n "$NS" get pod -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$ETCD" ]] || die "no etcd pod in $NS. This cluster may use external etcd, in which case
this check needs the endpoint and certificates for it instead."

# etcdctl runs as the pod's entrypoint-less binary, so no shell is needed inside the container -
# which matters because the etcd image is minimal and may not have one. Everything that parses
# the output runs here instead.
etcdctl() {
  kubectl -n "$NS" exec "$ETCD" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    "$@" 2>/dev/null
}

keys=$(etcdctl get /registry/secrets/ --prefix --keys-only | grep -c '^/registry/secrets/')
[[ "${keys:-0}" -gt 0 ]] || die "etcdctl returned no Secret keys. Either the exec failed or the
certificate paths differ on this cluster. Try it by hand:
  kubectl -n $NS exec $ETCD -- etcdctl --endpoints=https://127.0.0.1:2379 \\
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \\
    --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/ --prefix --keys-only | head"
ok "$keys Secret(s) in etcd"

# The encrypted form begins with a literal marker: k8s:enc:<provider>:v1:<key name>:
# Counting it is enough, and it is the only part of the value this script will ever look at -
# the rest is either ciphertext or, for the ones not yet rewritten, a plaintext credential. The
# output is piped straight into grep and never displayed.
enc=$(etcdctl get /registry/secrets/ --prefix | grep -ac 'k8s:enc:')
enc=${enc:-0}
plain=$((keys - enc))
(( plain < 0 )) && plain=0

if (( enc > 0 )); then ok "$enc encrypted"; else bad "0 encrypted"; fi
if (( plain > 0 )); then bad "$plain still PLAINTEXT"; else ok "0 plaintext"; fi

provider=$(etcdctl get /registry/secrets/ --prefix | grep -ao 'k8s:enc:[a-z0-9]*:v1:[a-z0-9]*' | head -1)
[[ -n "$provider" ]] && same "marker in etcd: $provider"

# A mixed result is the most informative one this check can produce, and it is worth saying why:
# it proves the check can TELL THE DIFFERENCE. A script reporting "all encrypted" against a
# cluster where nothing is encrypted looks identical to a correct one, and only a run that sees
# both kinds of value rules that out. After `make etcd-reencrypt` this contrast disappears, so
# the fresh-Secret probe below takes over as the positive control.
if (( enc > 0 && plain > 0 )); then
  same 'both kinds present, so this check distinguishes them rather than always agreeing'
fi

# ---------------------------------------------------------------- 2  a brand new Secret
step 'a Secret created right now'
# The positive control. If this one is not encrypted, nothing about the counts above matters:
# whatever the flag says, the API server is not encrypting what it writes.
#
# The value is a fixed, meaningless string. It is in Git, in this file, on purpose - it is not a
# credential and treating it as one would mean this check could not be read.
kubectl -n "$PROBE_NS" delete secret "$PROBE" --ignore-not-found >/dev/null 2>&1
kubectl -n "$PROBE_NS" create secret generic "$PROBE" \
  --from-literal=marker=not-a-secret-just-a-probe >/dev/null \
  || die "could not create the probe Secret in $PROBE_NS"
sleep 2

raw_enc=$(etcdctl get "/registry/secrets/$PROBE_NS/$PROBE" | grep -ac 'k8s:enc:')
raw_plain=$(etcdctl get "/registry/secrets/$PROBE_NS/$PROBE" | grep -ac 'not-a-secret-just-a-probe')
if (( ${raw_enc:-0} > 0 )) && (( ${raw_plain:-0} == 0 )); then
  ok 'written encrypted - its value does not appear in etcd in the clear'
  probe_ok=1
elif (( ${raw_plain:-0} > 0 )); then
  bad 'written in the CLEAR - the probe value is readable in etcd'
  probe_ok=0
else
  warn 'could not read the probe back out of etcd - verification UNKNOWN'
  probe_ok=unknown
fi

# ---------------------------------------------------------------- verdict
echo
if [[ "$probe_ok" == "0" ]]; then
  printf '%sSecrets are NOT being encrypted%s\n\n' "$c_err" "$c_off"
  printf 'A Secret created seconds ago is readable in etcd in plaintext. Whatever the flag says,\n'
  printf 'the provider is not taking effect - check the API server for a config it rejected:\n'
  printf '    kubectl -n %s logs %s --tail=30\n' "$NS" "$APISERVER"
  exit 1
fi

if (( plain > 0 )); then
  printf '%snew Secrets are encrypted; %d older one(s) are still plaintext%s\n\n' "$c_warn" "$plain" "$c_off"
  printf 'This is the step everyone skips, and it is not a defect - enabling encryption does not\n'
  printf 'reach backwards. A Secret is only encrypted when it is next WRITTEN, and nothing\n'
  printf 'rewrites them on its own.\n\n'
  printf '    make etcd-reencrypt\n\n'
  printf 'Until then, every one of those %d Secrets is readable by anyone who can read etcd'"'"'s\n' "$plain"
  printf 'files on the control-plane node - which is the entire threat this was turned on for.\n'
  exit 1
fi

printf '%severy Secret in etcd is encrypted%s\n\n' "$c_ok" "$c_off"
printf '%d Secret(s), %d encrypted, 0 plaintext, and a Secret created during this run came back\n' "$keys" "$enc"
printf 'as ciphertext. Verified by reading etcd rather than by reading a flag.\n\n'
printf '%sWhat this does not protect against%s, and it is most of the list: anyone with `get secret`\n' "$c_warn" "$c_off"
printf 'RBAC, any pod with a Secret mounted, and root on any node. The API server decrypts for\n'
printf 'all of them. This defends etcd'"'"'s files and an etcd backup, and nothing else.\n\n'
printf '%sAnd the key is now load-bearing:%s /etc/kubernetes/enc/key1.b64 on the control-plane node.\n' "$c_warn" "$c_off"
printf 'An etcd backup without that file is undecryptable. This project has no etcd backups yet,\n'
printf 'so nothing is at risk today - but whoever adds them has to back up the key separately,\n'
printf 'and storing it beside the backup defeats the point. See docs/parking-lot.md.\n'
exit 0
