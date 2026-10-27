#!/usr/bin/env bash
# Everything that can be checked without a cluster. Run before pushing.
#
#   make lint
#
# This lives in a script rather than in the Makefile because three separate bugs came from
# multi-line shell inside a Make recipe: Make consumes the backslash in a continuation and
# passes the rest through, so a quoted multi-line program arrives at jq or python with literal
# backslashes in it. Recipes here stay one line each.
#
# And there are NO pipes in the checks. `ansible-playbook --syntax-check | tail -2` reports
# TAIL's exit status, not ansible's - which is how a YAML error once passed a check that looked
# like it ran.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

c_hdr=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
fail=0

step() { printf '%s==> %s%s\n' "$c_hdr" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n'  "$c_ok" "$*" "$c_off"; }
bad()  { printf '    %s%s%s\n'  "$c_err" "$*" "$c_off"; fail=1; }
skip() { printf '    %s%s%s\n'  "$c_dim" "$*" "$c_off"; }

step 'Ansible playbooks parse'
for p in ansible/playbooks/*.yml; do
  if ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook "$p" --syntax-check >/dev/null 2>&1; then
    ok "$p"
  else
    bad "$p"
    ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook "$p" --syntax-check 2>&1 | sed 's/^/      /'
  fi
done

step 'YAML files parse'
# gitops/charts/*/templates/ is EXCLUDED on purpose. Those are Go templates, not YAML: a line
# like `{{- if .Values.x }}` is a syntax error to any YAML parser, and only `helm template` can
# say whether they are valid. Linting them as YAML reports a failure on correct files, which is
# worse than not checking them - a linter that cries wolf gets ignored.
#
# They are checked by `make gitops-render`, which is the real test.
python3 - <<'PY'
import glob, sys, yaml
bad = []
files = sorted({
    f
    for pat in ("ansible/**/*.yml", "ansible/**/*.yaml", "gitops/**/*.yaml", "clusters/**/*.json")
    for f in glob.glob(pat, recursive=True)
})
for f in files:
    if "/templates/" in f:
        print(f"    \033[2mskip (go template)  {f}\033[0m")
        continue
    try:
        if f.endswith(".json"):
            import json; json.load(open(f))
        else:
            list(yaml.safe_load_all(open(f)))
        print(f"    \033[32m{f}\033[0m")
    except Exception as e:
        print(f"    \033[31m{f}: {e}\033[0m")
        bad.append(f)
sys.exit(1 if bad else 0)
PY
[[ $? -eq 0 ]] || fail=1

step 'Shell scripts parse'
for s in scripts/*.sh; do
  bash -n "$s" && ok "$s" || bad "$s"
done

step 'Helm charts render'
# The real check for the template files skipped above. A chart with templates that do not render
# is a chart Argo CD will reject at sync time, which is a much worse place to find out.
if command -v helm >/dev/null 2>&1; then
  for chart in gitops/charts/*/; do
    name=$(basename "$chart")
    # Reuse gitops-render.sh rather than reimplementing the helm invocation. Two copies of
    # "how a chart is rendered" is how lint and render come to disagree, and then one of them
    # is wrong without anyone noticing - which is exactly what happened with the namespace.
    if bash scripts/gitops-render.sh "$name" onprem >/dev/null 2>&1; then
      ok "$name"
    else
      bad "$name"
      bash scripts/gitops-render.sh "$name" onprem 2>&1 | tail -5 | sed 's/^/      /'
    fi
  done
else
  skip 'helm not installed, skipped'
fi

step 'Terraform formatting'
if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive terraform/ && ok 'formatted' || bad 'run: terraform fmt -recursive terraform/'
else
  skip 'terraform not installed, skipped'
fi

step 'Load balancer addresses agree between nodes.json and the on-prem overlay'
# The same three values live in clusters/onprem/nodes.json (where hosts-sync and the docs read
# them) and in gitops/environments/onprem/platform-ingress.yaml (where Argo CD reads them).
# One source of truth would be better, but Argo CD renders a Helm chart from Git and cannot
# reach into nodes.json - so the honest options are duplication with a check, or a generator
# that makes the overlay a build artifact. Duplication with a check is less machinery and the
# failure is loud.
#
# What this prevents: editing the pool in one file, Argo CD announcing a range the workstation
# does not expect, and `gw.platform.local` resolving to an address nothing answers on.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCHECK'
import json, sys, yaml
n = json.load(open('clusters/onprem/nodes.json'))['loadbalancer']
o = yaml.safe_load(open('gitops/environments/onprem/platform-ingress.yaml'))
pairs = [
    ('pool start',       n['pool_start'],       o['loadBalancer']['poolStart']),
    ('pool stop',        n['pool_stop'],        o['loadBalancer']['poolStop']),
    ('gateway address',  n['gateway_address'],  o['gateway']['address']),
    ('gateway hostname', n['gateway_hostname'], o['gateway']['hostname']),
]
bad = [(w, a, b) for w, a, b in pairs if a != b]
for w, a, b in bad:
    print('    %s: nodes.json says %s, the overlay says %s' % (w, a, b))

# The pinned Gateway address must also be INSIDE the pool, or LB-IPAM cannot satisfy it and the
# Gateway stays un-Programmed with no obvious reason.
import ipaddress as ip
lo, hi = ip.IPv4Address(n['pool_start']), ip.IPv4Address(n['pool_stop'])
gw = ip.IPv4Address(n['gateway_address'])
if not (lo <= gw <= hi):
    print('    gateway address %s is outside the pool %s-%s' % (gw, lo, hi))
    bad.append(1)

# And it must not collide with a node.
for node in json.load(open('clusters/onprem/nodes.json'))['nodes']:
    if ip.IPv4Address(node['address']) >= lo and ip.IPv4Address(node['address']) <= hi:
        print('    node %s (%s) is inside the load balancer pool' % (node['name'], node['address']))
        bad.append(1)

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'addresses agree, gateway inside the pool, no node collision'
  else bad 'fix the mismatch above - nodes.json is the source of truth'
  fi
else
  skip 'jq or python3 missing, skipped'
fi

step 'Optional linters, where installed'

command -v yamllint     >/dev/null 2>&1 && { yamllint -s . && ok yamllint || bad yamllint; } || skip 'yamllint not installed'
command -v ansible-lint >/dev/null 2>&1 && { ansible-lint ansible/ && ok ansible-lint || bad ansible-lint; } || skip 'ansible-lint not installed'

echo
if [[ $fail -eq 0 ]]; then
  printf '%slint clean%s\n' "$c_ok" "$c_off"
else
  printf '%slint FAILED%s\n' "$c_err" "$c_off"
fi
exit $fail
