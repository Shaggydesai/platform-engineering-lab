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

step 'Helm charts render, in every environment that actually deploys them'
# The real check for the template files skipped above. A chart with templates that do not render
# is a chart Argo CD will reject at sync time, which is a much worse place to find out.
#
# IT USED TO RENDER EVERY CHART AGAINST onprem AND ONLY onprem, which was correct while there was
# one cluster and became a hole the moment there were two. gitops/environments/gcp/ had existed
# for several modules, unrendered and unchecked, because nothing deployed from it - and the first
# thing that did (cert-manager on GKE, ADR-0020) would have found out at sync time.
#
# The pairs come from the APPLICATIONS rather than from a list here, so the coverage grows on its
# own: adding gitops/clusters/<env>/platform/<chart>.yaml is what makes that overlay checked. A
# list would have to be remembered, and the module that adds a component is the module least
# likely to remember it.
#
# Deliberately NOT every chart against every environment. An overlay with no Application deploys
# nothing, so a failure in it is not yet a failure - and `aws` is seven such files. Rendering
# them would report problems that cannot be fixed against decisions that have not been made.
if command -v helm >/dev/null 2>&1; then
  for chart in gitops/charts/*/; do
    name=$(basename "$chart")
    found=0
    for app in gitops/clusters/*/platform/"$name".yaml; do
      [[ -f "$app" ]] || continue
      found=1
      # gitops/clusters/<env>/platform/<chart>.yaml -> <env>
      env=$(basename "$(dirname "$(dirname "$app")")")
      # Reuse gitops-render.sh rather than reimplementing the helm invocation. Two copies of
      # "how a chart is rendered" is how lint and render come to disagree, and then one of them
      # is wrong without anyone noticing - which is exactly what happened with the namespace.
      if bash scripts/gitops-render.sh "$name" "$env" >/dev/null 2>&1; then
        ok "$name ($env)"
      else
        bad "$name ($env)"
        bash scripts/gitops-render.sh "$name" "$env" 2>&1 | tail -5 | sed 's/^/      /'
      fi
    done
    # A chart nothing deploys. Not a failure - it is how a component arrives, one module before
    # the Application that uses it - but silence here would hide a chart that has stopped
    # rendering, so it is reported.
    (( found )) || skip "$name - no Application in any cluster, so nothing renders it"
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

# The wildcard the certificate is issued for, and every name expected to be covered by it.
# A name that does not match the wildcard gets a certificate error that reads like a CA
# problem rather than a naming one, which is an afternoon to track down (ADR-0014).
wild = n.get('gateway_wildcard', '')
if wild != o['gateway'].get('wildcardHostname'):
    print('    wildcard: nodes.json says %s, the overlay says %s'
          % (wild, o['gateway'].get('wildcardHostname')))
    bad.append(1)

names = n.get('gateway_hostnames') or [n['gateway_hostname']]
if wild.startswith('*.'):
    suffix = wild[1:]                      # '.platform.local'
    for h in names:
        # A wildcard covers exactly ONE extra label: *.platform.local matches
        # argocd.platform.local but not a.b.platform.local, and not platform.local itself.
        label = h[:-len(suffix)] if h.endswith(suffix) else None
        if label is None or not label or '.' in label:
            print('    %s is not covered by the certificate wildcard %s' % (h, wild))
            bad.append(1)

if n['gateway_hostname'] not in names:
    print('    gateway_hostname %s is missing from gateway_hostnames, so `make hosts` will not '
          'write it' % n['gateway_hostname'])
    bad.append(1)

# Every route's hostname must be a name the workstation can resolve, or the route works and
# nothing can reach it.
for rname, r in (o.get('routes') or {}).items():
    if r.get('enabled') and r.get('hostname') and r['hostname'] not in names:
        print('    route %s uses %s, which is not in gateway_hostnames - nothing will resolve it'
              % (rname, r['hostname']))
        bad.append(1)

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'addresses agree, gateway inside the pool, no node collision'
  else bad 'fix the mismatch above - nodes.json is the source of truth'
  fi
else
  skip 'jq or python3 missing, skipped'
fi

step 'Every seam file an inventory names actually exists'
# The argocd role applies whatever `argocd_seam_files` lists, per substrate (ADR-0020). A name in
# that list with no file behind it fails inside the playbook at `kubectl diff`, against a cluster,
# after Argo CD has already been installed - which is a slow and expensive way to find a typo.
#
# It also catches the reverse mistake, which is the one that would actually happen: adding a root
# Application to gitops/bootstrap/ and forgetting to add it to the inventory. The file then sits
# in Git looking deployed and nothing ever applies it, which is silent.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCHECK'
import ast, glob, json, os, re, subprocess, sys
bad = []
named = set()

# EVERY INVENTORY, FOUND BY GLOB. This check named two files for as long as there were two, and
# the third one landing is what would have made it silently incomplete - the same shape as
# cost-check's two hardcoded AWS regions (parking lot, 2026-11-04). A list somebody wrote is
# exactly as complete as the day they wrote it.
def seam_files(inv):
    """The seam files an inventory names, and HOW we found out - which is not always the same way.

    Running `--list` is the strong answer: it is the value Ansible will actually receive. But
    ansible/inventory/aws.py reads node addresses from Terraform state, so it cannot list on a
    laptop with no AWS cluster up - and a lint step that fails whenever a substrate is torn down
    is a lint step people learn to ignore.

    So: run it when it runs, and fall back to reading the literal out of the source when it does
    not. The fallback is weaker - it cannot see a value computed at runtime - and it is stated as
    such rather than passed off as equivalent.
    """
    out = subprocess.run([sys.executable, inv, '--list'], capture_output=True, text=True)
    if out.returncode == 0:
        try:
            return json.loads(out.stdout)['all']['vars'].get('argocd_seam_files', []), 'live'
        except (ValueError, KeyError):
            pass
    tree = ast.parse(open(inv, encoding='utf-8').read())
    for node in ast.walk(tree):
        if (isinstance(node, ast.Compare) or not isinstance(node, ast.Dict)):
            continue
        for k, v in zip(node.keys, node.values):
            if (isinstance(k, ast.Constant) and k.value == 'argocd_seam_files'
                    and isinstance(v, (ast.List, ast.Tuple))):
                vals = [e.value for e in v.elts if isinstance(e, ast.Constant)]
                if len(vals) == len(v.elts):
                    return vals, 'source'
    return [], 'unreadable'

for inv in sorted(glob.glob('ansible/inventory/*.py')):
    files, how = seam_files(inv)
    if how == 'unreadable':
        print('    %s: could not determine its seam files either way' % inv)
        bad.append(inv); continue
    if how == 'source':
        print('    %s: read from source - it cannot --list without its substrate built' % inv)
    if not files:
        print('    %s names no seam files at all' % inv)
        bad.append(inv); continue
    # projects.yaml first, always: an Application referencing a missing AppProject is rejected,
    # and the role applies this list in order.
    if files[0] != 'projects.yaml':
        print('    %s lists %s first - projects.yaml must be first, or the roots are rejected'
              % (inv, files[0]))
        bad.append(inv)
    for f in files:
        named.add(f)
        if not os.path.isfile(os.path.join('gitops/bootstrap', f)):
            print('    %s names gitops/bootstrap/%s, which does not exist' % (inv, f))
            bad.append(f)

# And the other direction: a root Application committed but named by no inventory.
for f in sorted(os.listdir('gitops/bootstrap')):
    if f.endswith('.yaml') and f not in named:
        print('    gitops/bootstrap/%s is in Git but no inventory applies it' % f)
        bad.append(f)

# AND THE PATH EACH ROOT POINTS AT MUST CONTAIN SOMETHING.
#
# Added after this check passed clean on a root Application whose directory did not exist at all.
# Argo CD does not treat that as an error: it syncs an empty directory, reports Synced/Healthy,
# and installs nothing. So the seam would have looked correct on the cluster while delivering no
# platform - a check agreeing with whoever wrote it, which is the shape this repository keeps
# finding in its own checks.
#
# The path is read out of the Application rather than guessed from the filename, because
# root-aws.yaml pointing at gitops/clusters/gcp/platform is exactly the copy-paste this catches.
for f in sorted(os.listdir('gitops/bootstrap')):
    if not f.endswith('.yaml') or f == 'projects.yaml':
        continue
    text = open(os.path.join('gitops/bootstrap', f), encoding='utf-8').read()
    m = re.search(r'^\s*path:\s*(\S+)\s*$', text, re.M)
    if not m:
        print('    gitops/bootstrap/%s declares no source path' % f)
        bad.append(f); continue
    path = m.group(1).strip('"\'')
    if not os.path.isdir(path):
        print('    gitops/bootstrap/%s points at %s, which does not exist' % (f, path))
        bad.append(f)
    elif not [y for y in os.listdir(path) if y.endswith('.yaml')]:
        print('    gitops/bootstrap/%s points at %s, which contains no yaml - Argo CD would sync'
              ' it clean and install nothing' % (f, path))
        bad.append(f)

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'every inventory names files that exist, and nothing in bootstrap is orphaned'
  else bad 'fix the mismatch above - ansible/inventory/*.py and gitops/bootstrap/ must agree'
  fi
else
  skip 'python3 missing, skipped'
fi

step 'Every Terraform state has its provider lock file committed'
# THE LOCK FILE IS THE REAL PIN, and this repository says so in a comment and then did not check
# it. terraform/gcp/guardrails/versions.tf states the rule at length: versions.tf pins 6.50.0,
# .terraform.lock.hcl carries the provider's HASHES, so a re-published 6.50.0 would fail
# verification rather than install quietly.
#
# Two of the four states did not have one committed when this check was written - the GKE cluster
# state, missing since the day it was created, and the secret backend, missing because the output
# that reminds you to commit it only exists in the guardrail state. A rule stated in a comment and
# enforced nowhere is a rule that is true of whichever file someone remembered.
#
# `git ls-files` rather than `test -f`: the question is whether it is in the REPOSITORY, not
# whether it is on this machine. A lock file only appears after `terraform init`, so a fresh
# clone has none on disk and that is exactly the case the commit protects.
#
# AND A STATE THAT HAS NEVER BEEN INITIALISED IS NOT A VIOLATION, which this check originally
# could not express. A lock file can only be produced by `terraform init`, so a state written in
# an environment that cannot reach registry.terraform.io has none and cannot have one - which is
# exactly the position terraform/gcp/guardrails was in for one commit, and terraform/aws/guardrails
# is in now. Failing on it would make `make lint` red on a fresh pull for a rule the reader has no
# way to satisfy yet, and a lint that is red for a known-acceptable reason stops being read.
#
# The signal is in the file: a version CONSTRAINT with a range in it (">= 5.0.0, < 6.0.0") is a
# declaration that init has not run, because the whole point of the range is that the real version
# is not known yet. An EXACT pin means someone read a resolution and wrote it down - at which
# point the lock file exists on their machine and must be committed. So the rule closes itself:
# pinning the version is what makes the missing lock a failure.
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  missing=''
  pending=''
  for d in $(grep -rl 'required_providers' terraform --include='*.tf' 2>/dev/null \
             | xargs -r -n1 dirname | sort -u); do
    git ls-files --error-unmatch "$d/.terraform.lock.hcl" >/dev/null 2>&1 && continue
    # A range constraint anywhere in the directory's version pins: >=, <=, <, ~>, or a comma.
    if grep -hE '^[[:space:]]*version[[:space:]]*=' "$d"/*.tf 2>/dev/null \
       | grep -qE '(>=|<=|~>|<|,)'; then
      pending="$pending $d"
    else
      missing="$missing $d"
    fi
  done
  if [ -z "$missing" ] && [ -z "$pending" ]; then
    ok 'all provider lock files are in Git'
  elif [ -z "$missing" ]; then
    for d in $pending; do
      printf '    %s%s still has a RANGE constraint, so no lock file is expected yet%s\n' \
        "$c_dim" "$d" "$c_off"
    done
    ok 'every state with an exact version pin has its lock file committed'
    printf '      %sthe first `terraform init` in a pending state resolves a real version: pin it\n' "$c_dim"
    printf '      exactly in versions.tf and commit the lock, and this check starts enforcing it%s\n' "$c_off"
  else
    for d in $missing; do printf '    %s/.terraform.lock.hcl is not committed\n' "$d"; done
    bad 'commit them - the version is pinned exactly, so init has run and the lock file exists'
    printf '      %sfor d in%s; do git add -f "$d/.terraform.lock.hcl"; done%s\n' \
      "$c_dim" "$missing" "$c_off"
  fi
else
  skip 'not a git checkout, skipped'
fi

step 'The GCP secret backend agrees with cluster.json and with its Terraform'
# Exactly the same shape of problem as the check above, one substrate over, and the same honest
# trade: Argo CD renders a Helm chart from Git and cannot reach into clusters/gcp/cluster.json, so
# the project ID, the zone, the cluster name and the service account email are written out
# literally in gitops/environments/gcp/external-secrets.yaml. Duplication with a check, rather
# than a generator that makes the overlay a build artifact.
#
# WHAT EACH MISMATCH WOULD ACTUALLY DO, because they fail in different and unhelpful ways:
#
#   wrong projectID        the store looks for the secret in a project that does not have it, and
#                          reports NotFound on a secret that plainly exists in the console
#   wrong clusterLocation  the region instead of the zone - the store cannot find its own cluster
#   wrong service account  Workload Identity exchanges the token for an account with no grant,
#                          and the error is a 403 that reads like a missing role
#
# All three produce a ClusterSecretStore that is Ready=False with a message about the backend,
# several layers from a one-character typo in this file.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCHECK'
import json, re, sys, yaml

cfg = json.load(open('clusters/gcp/cluster.json'))
ov  = yaml.safe_load(open('gitops/environments/gcp/external-secrets.yaml'))

# Read the names out of Terraform's locals rather than repeating them a third time here. A
# regex over HCL is crude, and it is still better than a third copy of the string: if the
# pattern stops matching, the value comes back None and the comparison fails loudly.
hcl = open('terraform/gcp/secrets/variables.tf').read()
def local(name, default=None):
    m = re.search(r'^\s*%s\s*=\s*"([^"]*)"' % re.escape(name), hcl, re.M)
    return m.group(1) if m else default

gsa_id    = local('gsa_id')
secret_id = local('secret_id')
ksa_ns    = local('ksa_namespace')
ksa_name  = local('ksa_name')

gcpsm = (ov.get('secretStore') or {}).get('provider', {}).get('gcpsm') or {}
wi    = (gcpsm.get('auth') or {}).get('workloadIdentity') or {}
sa    = ((ov.get('external-secrets') or {}).get('serviceAccount') or {}).get('annotations') or {}

want_gsa = '%s@%s.iam.gserviceaccount.com' % (gsa_id, cfg['project_id'])

pairs = [
    ('projectID',       cfg['project_id'], gcpsm.get('projectID')),
    ('clusterLocation', cfg['zone'],       wi.get('clusterLocation')),
    ('clusterName',     'platform',        wi.get('clusterName')),
    ('gcp-service-account annotation', want_gsa, sa.get('iam.gke.io/gcp-service-account')),
    # The namespace/name pair the Workload Identity binding is written against. A different
    # value here is a pod whose token Google will not exchange at all.
    ('serviceAccountRef.name',      ksa_name, (wi.get('serviceAccountRef') or {}).get('name')),
    ('serviceAccountRef.namespace', ksa_ns,   (wi.get('serviceAccountRef') or {}).get('namespace')),
]
bad = []
for what, want, got in pairs:
    if want != got:
        print('    %s: expected %r, the overlay says %r' % (what, want, got))
        bad.append(what)

# The destination namespace of the Application must equal the one in the binding, for the same
# reason - and it is in a third file, which is exactly why this is checked rather than trusted.
app = yaml.safe_load(open('gitops/clusters/gcp/platform/external-secrets.yaml'))
app_ns = (app.get('spec') or {}).get('destination', {}).get('namespace')
if app_ns != ksa_ns:
    print('    Application destination namespace is %r, the Workload Identity binding names %r'
          % (app_ns, ksa_ns))
    bad.append('destination')

# Secret Manager secret IDs match [A-Za-z0-9_-]+ and forbid the slash Vault's paths use. The
# tenant overlay's remoteKey is the Secret Manager ID on this substrate, so a value copied
# across from the on-prem overlay would be rejected by the API rather than merely not found.
if secret_id and not re.fullmatch(r'[A-Za-z0-9_-]+', secret_id):
    print('    secret_id %r is not a legal Secret Manager ID ([A-Za-z0-9_-]+)' % secret_id)
    bad.append('secret_id')

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'project, zone, cluster, service account and namespace all agree'
  else bad 'fix the mismatch above - cluster.json and terraform/gcp/secrets are the source of truth'
  fi
else
  skip 'python3 missing, skipped'
fi

step 'The budget guardrails agree with the scripts that verify them'
# A DIFFERENT KIND OF DRIFT FROM THE CHECK ABOVE, and the cheaper one to let happen.
#
# The budget AMOUNT and the THRESHOLDS cannot disagree between cluster.json and the Terraform,
# because the Terraform reads cluster.json with jsondecode(file(...)). That is the design and it
# needs no check.
#
# WHAT CAN DISAGREE IS THE NAME. terraform/aws/guardrails/main.tf writes the budget's name as a
# literal, and scripts/aws-guardrails-verify.sh looks the budget up BY that name as a second
# literal in a second file. Rename it in one place and the verifier reports "NO budget named ..."
# about a budget that exists and is correct - then sends someone to re-apply it, which succeeds,
# changes nothing, and leaves the check still failing. A false negative on the one gate that
# stands between this repository and a billable cluster.
#
# The same shape exists on the GCP side (display_name vs the script's PREFIX), so both are checked.
#
# The notification SEMANTICS are checked for the same reason: the verifier asserts ACTUAL,
# GREATER_THAN and PERCENTAGE, and it builds the --notification lookup key out of those three
# values. If main.tf ever used FORECASTED, the lookup would find no subscribers and the script
# would report "NO subscriber" for every threshold on a budget whose subscribers are all present.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCHECK'
import re, sys
bad = []

def read(p):
    try:
        return open(p).read()
    except OSError as e:
        print('    cannot read %s: %s' % (p, e))
        bad.append(p)
        return ''

aws_tf = read('terraform/aws/guardrails/main.tf')
aws_sh = read('scripts/aws-guardrails-verify.sh')
gcp_tf = read('terraform/gcp/guardrails/main.tf')
gcp_sh = read('scripts/gcp-guardrails-verify.sh')

# --- AWS: the budget name, in two files
m = re.search(r'^\s*name\s*=\s*"([^"]+)"', aws_tf, re.M)
tf_name = m.group(1) if m else None
m = re.search(r'^NAME="([^"]+)"', aws_sh, re.M)
sh_name = m.group(1) if m else None
if not tf_name or not sh_name:
    print('    could not find the AWS budget name in both files (tf=%r sh=%r)' % (tf_name, sh_name))
    bad.append('aws-name-unreadable')
elif tf_name != sh_name:
    print('    AWS budget name differs: main.tf %r vs verify script %r' % (tf_name, sh_name))
    bad.append('aws-name')

# --- AWS: the three values that make up the verifier's notification lookup key
for field, want in (('budget_type', 'COST'),
                    ('time_unit', 'MONTHLY'),
                    ('notification_type', 'ACTUAL'),
                    ('comparison_operator', 'GREATER_THAN'),
                    ('threshold_type', 'PERCENTAGE')):
    m = re.search(r'^\s*%s\s*=\s*"([^"]+)"' % field, aws_tf, re.M)
    got = m.group(1) if m else None
    if got != want:
        print('    terraform/aws/guardrails/main.tf %s is %r; the verifier assumes %r'
              % (field, got, want))
        bad.append(field)

# The verifier builds its lookup key from those values; confirm it really does, so that changing
# main.tf and this list together cannot silently leave the script behind.
key = 'NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN'
if key not in aws_sh:
    print('    scripts/aws-guardrails-verify.sh no longer builds its lookup key as %r' % key)
    bad.append('aws-lookup-key')
if 'ThresholdType=PERCENTAGE' not in aws_sh:
    print('    scripts/aws-guardrails-verify.sh lookup key is missing ThresholdType=PERCENTAGE')
    bad.append('aws-lookup-threshold-type')

# --- AWS: both sides must read the same config file
if 'clusters/aws/cluster.json' not in aws_sh:
    print('    scripts/aws-guardrails-verify.sh does not read clusters/aws/cluster.json')
    bad.append('aws-cfg-script')
if 'clusters/aws/cluster.json' not in read('terraform/aws/guardrails/variables.tf'):
    print('    terraform/aws/guardrails does not read clusters/aws/cluster.json')
    bad.append('aws-cfg-tf')

# --- GCP: the script matches budgets by PREFIX, so the display_name must START with it
m = re.search(r'^PREFIX="([^"]+)"', gcp_sh, re.M)
gcp_prefix = m.group(1) if m else None
m = re.search(r'^\s*display_name\s*=\s*"([^"]+)"', gcp_tf, re.M)
gcp_display = m.group(1) if m else None
if not gcp_prefix or not gcp_display:
    print('    could not find the GCP budget name in both files (tf=%r sh=%r)'
          % (gcp_display, gcp_prefix))
    bad.append('gcp-name-unreadable')
elif not gcp_display.startswith(gcp_prefix):
    print('    GCP display_name %r does not start with the verifier PREFIX %r'
          % (gcp_display, gcp_prefix))
    bad.append('gcp-name')

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'budget names and notification semantics match on both substrates'
  else bad 'fix the mismatch above - a renamed budget makes the gate fail on a correct guardrail'
  fi
else
  skip 'python3 missing, skipped'
fi


step 'The AWS and on-prem Kubernetes pins agree'
# DUPLICATION WITH A CHECK, rather than coupling without one.
#
# clusters/aws/cluster.json repeats seven values from clusters/onprem/nodes.json: the Kubernetes
# version, the CNI and its version, the Gateway API version and its content digest, and the two
# CIDRs. Having the AWS inventory READ the on-prem file would remove the duplication and create a
# worse problem - an AWS build failing because somebody edited the laptop's config - which is the
# coupling ADR-0008 exists to avoid.
#
# WHAT EACH MISMATCH WOULD DO, because they fail in different and unhelpful ways:
#
#   version              preflight refuses the build: a control plane newer than its kubelets is
#                        supported in one direction only and obscure when it breaks. But the
#                        image scripts install from `minor`, so a disagreement between `minor`
#                        and `version` is the one that gets through and bites at join time.
#   cilium_version       two substrates running different dataplanes, compared as though they
#                        were the same one - which quietly spoils every Module 09 measurement.
#   gateway_api_sha256   the role verifies the digest before applying and refuses on a mismatch,
#                        so this fails loudly. Good. It is checked anyway because a digest copied
#                        wrong is indistinguishable from a tampered download.
#   pod_cidr/service_cidr  changing either after kubeadm has run means rebuilding the cluster
#                        (ADR-0007), so they must be right before the first apply, not after.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCHECK'
import json, sys
aws = json.load(open('clusters/aws/cluster.json'))['kubernetes']
onp = json.load(open('clusters/onprem/nodes.json'))['kubernetes']
bad = []
for k in ("minor", "version", "package_version", "cni", "cilium_version", "gateway_api_version",
          "gateway_api_sha256", "pod_cidr", "service_cidr"):
    a, o = aws.get(k), onp.get(k)
    if a != o:
        print('    %-20s aws=%r  onprem=%r' % (k, a, o))
        bad.append(k)

# `minor` is what the image scripts pin the apt repository to, and `version` is what preflight
# asserts the installed kubeadm reports. A `version` outside its own `minor` installs one thing
# and demands another - and nothing else in this repository compares them.
minor, version = aws.get("minor", ""), aws.get("version", "")
if minor and version and not version.startswith(minor + "."):
    print('    minor %r does not contain version %r - the image installs one and preflight wants the other'
          % (minor, version))
    bad.append('minor')

# AND package_version IS WHAT APT ACTUALLY INSTALLS, while `version` is what preflight asserts
# kubeadm reports. They are different strings for the same thing - "1.34.12-1.1" against
# "v1.34.12" - so nothing compares them unless something is told to.
#
# Added after the two disagreed in the only way that matters: 30-kubernetes.sh installed
# "newest in the v1.34 repo", which was v1.34.12 when the laptop image was baked and v1.34.13
# when cloud-init ran it on EC2 five modules later. Preflight caught it, on the substrate where
# the scripts run fresh - and the same bug had been sitting in the Packer path the whole time,
# invisible because an image is baked once.
pkg = aws.get("package_version", "")
if version and pkg and not pkg.startswith(version.lstrip("v") + "-"):
    print('    package_version %r is not a packaging of version %r - apt would install one and'
          ' preflight would assert the other' % (pkg, version))
    bad.append('package_version')

sys.exit(1 if bad else 0)
PYCHECK
  then ok 'minor, version, package_version, CNI, Gateway API digest and both CIDRs agree, and the three version strings are consistent'
  else bad 'fix the mismatch above - clusters/onprem/nodes.json is the original'
  fi
else
  skip 'python3 missing, skipped'
fi

step "The Makefile's own references resolve"
# TWICE NOW, A MAKEFILE EDIT OF MINE HAS DELETED SOMETHING AND LINT HAS SAID CLEAN.
#
# First four targets (`_aws-preflight`, `aws-up`, `aws-wait`), caught by `git diff --stat`
# showing 107 deletions for a one-recipe change. Then `AWS_TF := terraform/aws`, which sat
# between two targets and was taken by a line-range replacement of the recipe above it - not
# caught at all, for three hours, while a cluster billed.
#
# THE SECOND ONE IS THE WORSE FAILURE MODE and it is specific to make: an undefined variable
# expands to the EMPTY STRING, silently. `cd $(AWS_TF)` becomes `cd`, which succeeds and lands
# in $HOME. So `make aws-up` reported "Terraform initialized in an empty directory" - and
# `make aws-down`, the one control standing between a forgotten cluster and a card, was equally
# broken and nobody had run it to find out.
#
# Two textual properties, no make invocation, no substrate:
#   every $(VAR) is defined in this Makefile, or is user-overridable (KNOWN_VARS), or is one of
#   make's own; and every prerequisite is a defined target or an existing file.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYMAKE'
import os, re, sys, pathlib

text = pathlib.Path("Makefile").read_text()

defined = set(re.findall(r'^([A-Z_][A-Z_0-9]*)\s*:?=', text, re.M))
known = set()
m = re.search(r'^KNOWN_VARS\s*:?=\s*((?:.*\\\n)*.*)$', text, re.M)
if m:
    known = set(m.group(1).replace("\\", " ").split())
# make's own, plus the environment ones a recipe may legitimately read.
builtin = {"MAKE", "MAKEFLAGS", "MAKEFILE_LIST", "CURDIR", "SHELL", "HOME", "PATH", "PWD",
           "USER", "MAKECMDGOALS", "VPATH", "SUFFIXES", ".DEFAULT_GOAL"}

# $(NAME) but NOT $$(NAME), which is shell command substitution rather than a make variable.
used = set(re.findall(r'(?<!\$)\$\(([A-Z_][A-Z_0-9]*)\)', text))
undefined = sorted(used - defined - known - builtin)

targets = set(re.findall(r'^([A-Za-z_][A-Za-z0-9_.-]*)\s*:(?!=)', text, re.M))
missing = []
for line in text.splitlines():
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_.-]*)\s*:(?!=)\s*([^#]*)', line)
    if not m:
        continue
    for pre in m.group(2).split():
        if pre.startswith("$"):            # computed prerequisite, not checkable textually
            continue
        if pre in targets or os.path.exists(pre):
            continue
        missing.append((m.group(1), pre))

for v in undefined:
    print(f"  $({v}) is used but never defined - make expands it to the empty string")
for tgt, pre in missing:
    print(f"  target {tgt!r} needs {pre!r}, which is neither a target here nor a file")

if not undefined and not missing:
    print(f"  {len(used)} variable reference(s) and {len(targets)} target(s), all resolved")
sys.exit(1 if (undefined or missing) else 0)
PYMAKE
  then ok "every variable the Makefile uses is defined, and every prerequisite exists"
  else bad 'an undefined make variable expands to the empty string - it will not fail loudly'
  fi
else
  skip 'python3 missing, skipped'
fi

step 'Only the control_plane role uses the fetched kubeconfig'
# THE RULE THIS CHECK EXISTS TO STOP ME BREAKING A FIFTH TIME.
#
# `kubeconfig_fetch_path` is where the control_plane role PUTS the admin.conf it fetched. That
# file names controlPlaneEndpoint, which on a cloud substrate is an address the workstation
# cannot route to - so anything else that runs kubectl or helm on localhost must use
# `cluster_kubeconfig`, the reachable copy that same role writes.
#
# That mistake appeared four times on 2026-11-05: the argocd role, then gateway_api, cilium and
# kube_proxy_removal together, then the verify play in cluster.yml. Each fix was applied to the
# files in front of me. The failure looks like `dial tcp 10.20.1.10:6443: i/o timeout` - a
# network error, from a cluster that is working, hundreds of lines into a playbook.
#
# Deliberately a grep rather than anything cleverer: the rule is "this name is USED in exactly
# one role", which is a textual property, checkable without Ansible, a cluster, or a substrate
# being up.
#
# A USE, not a mention. The first version of this check matched the name anywhere and failed on
# the comment in cluster.yml that explains the rule - a check that forbids writing down why it
# exists. So it looks for the name inside a Jinja expression, on a line that is not a comment:
# `{{ kubeconfig_fetch_path }}` is a use, and prose about it is not.
if command -v grep >/dev/null 2>&1; then
  hits=$(grep -rn '{{[^}]*kubeconfig_fetch_path' \
           --include='*.yml' --include='*.yaml' ansible/ 2>/dev/null \
         | grep -v '^ansible/roles/control_plane/' \
         | grep -v ':[0-9]*: *#' || true)
  if [[ -z "$hits" ]]; then
    ok 'only the control_plane role uses the fetched kubeconfig'
  else
    printf '%s\n' "$hits" | sed 's/^/  /'
    bad 'use cluster_kubeconfig - the fetched file names an address the workstation cannot reach'
  fi
else
  skip 'grep missing, skipped'
fi

step 'Any helper-image pin is a digest, not a tag'
# WHAT THIS CHECK CLAIMS, precisely: every environment where local-path is actually DEPLOYED
# pins its helper image by digest, and all of them pin the same one. Three other states are
# printed rather than passed over - not deployed, deployed but unpinned, and pinned malformed -
# because an `ok` that silently covers any of them is the failure most of this file guards against.
#
# "Deployed" is read from gitops/clusters/<env>/platform/local-path.yaml, not from the presence of
# an overlay. The first version of this check conflated the two and reported that busybox:latest
# was in use on aws and gcp, where the chart is not installed at all - those overlays exist to
# say so, since GKE and EKS ship their own default StorageClass.
#
# The distinction is the one this repository keeps paying for: a check whose "ok" covers a case it
# never examined. So the unpinned environments are listed every run, and the green line below says
# only what was verified.
#
# The shape is unusual and deliberate - the chart composes `{{ repository }}:{{ tag }}` with a
# literal colon, so a digest has to be split across the two values to render `repo@sha256:<hex>`.
# gitops/environments/onprem/local-path.yaml explains it at the point of use.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYHELPER'
import pathlib, re, sys, yaml

files = sorted(pathlib.Path("gitops/environments").glob("*/local-path.yaml"))
if not files:
    print("  no local-path overlays found")
    sys.exit(2)

bad, unpinned, absent = [], [], []
for f in files:
    env = f.parent.name
    # IS THE CHART EVEN DEPLOYED HERE? An overlay in gitops/environments/<env>/ is values for an
    # Application; if gitops/clusters/<env>/platform/ has no local-path.yaml, no Application
    # reads it and the helper image is not running on that substrate at all.
    #
    # The first version of this check skipped that question and reported "the chart default
    # docker.io/library/busybox:latest is in use" for aws and gcp, where local-path is NOT
    # deployed - GKE and EKS ship their own default StorageClass, which those two overlays say
    # in as many words. A check that overstates what it knows is the thing this check was
    # written to avoid, and it did it in its own first run.
    if not pathlib.Path("gitops/clusters") .joinpath(env, "platform", "local-path.yaml").is_file():
        absent.append(env)
        continue

    try:
        doc = yaml.safe_load(f.read_text()) or {}
    except yaml.YAMLError as e:
        print(f"  {f}: not parseable as YAML ({e})")
        bad.append(f)
        continue

    helper = doc.get("helperImage")
    if not helper:
        unpinned.append(f)
        continue

    repo = str(helper.get("repository", ""))
    tag = str(helper.get("tag", ""))
    if not repo.endswith("@sha256"):
        print(f"  {f}: helperImage.repository {repo!r} must end with '@sha256'")
        print( "    the chart appends ':' + tag, so the digest is split across the two values")
        bad.append(f)
    if not re.fullmatch(r"[0-9a-f]{64}", tag):
        print(f"  {f}: helperImage.tag {tag!r} is not 64 hex characters")
        print( "    a tag here is a mutable pointer; put the digest's hex in it, no 'sha256:' prefix")
        bad.append(f)

for f in unpinned:
    print(f"  {f}: no helperImage - the chart default docker.io/library/busybox:latest is in use")
if unpinned:
    print( "    open parking-lot item (2026-10-29). To close it:")
    print( "      scripts/image-digest.sh docker.io/library/busybox latest")

# EVERY DEPLOYED ENVIRONMENT MUST PIN THE SAME BYTES, which is the half that is about this
# project's premise rather than about supply chain. Three substrates each pinning a different
# helper image would be three different platforms wearing one definition - and it is the kind of
# drift nothing else here would notice, because each one would be individually valid.
digests = {}
for f in files:
    env = f.parent.name
    if env in absent:
        continue
    try:
        doc = yaml.safe_load(f.read_text()) or {}
    except yaml.YAMLError:
        continue
    h = (doc.get("helperImage") or {}).get("tag")
    if h:
        digests[env] = str(h)
if len(set(digests.values())) > 1:
    print("  deployed environments pin DIFFERENT helper images:")
    for env, h in sorted(digests.items()):
        print(f"    {env}: {h}")
    bad.append("disagreement")

if absent:
    print(f"  not deployed, so nothing to pin: {', '.join(sorted(absent))}"
          " (their clusters have no local-path Application)")
if digests and not bad:
    print(f"  pinned by digest: {', '.join(sorted(digests))}")

sys.exit(1 if bad else 0)
PYHELPER
  then ok 'every deployed environment pins its helper image by digest, and they agree'
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then skip 'no local-path overlays - see above'
    else bad 'a helper-image pin must render repo@sha256:<hex> - see the lines above'
    fi
  fi
else
  skip 'python3 missing, skipped'
fi

step 'Every Packer variable without a default is supplied'
# THE CHECK FOR EXACTLY TODAY'S BUG, written the hour it happened.
#
# `30-kubernetes.sh` had K8S_PACKAGE_VERSION made REQUIRED on 2026-11-05, because a default there
# meant "newest in the apt repo today" and produced a different Kubernetes on a different day.
# Removing a default is the right move and it silently broke the caller: `scripts/build-image.sh`
# ran `packer build .` with no `-var`, so the next image build would have stopped on a missing
# variable - and an image rebuild happens rarely and usually under time pressure.
#
# Packer's own behaviour is what makes this worth a check rather than a convention: a variable
# with no default and no value is not a parse error, it is an interactive prompt or a late
# failure, so `packer validate` in CI would not necessarily catch it either.
#
# ssh_public_key is the expected exception: build-image.sh WRITES it into
# variables.auto.pkrvars.hcl, which Packer loads automatically, and that file is gitignored
# because it holds this machine's key.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYPACKER'
import pathlib, re, sys

hcl_files = sorted(pathlib.Path("packer").rglob("*.pkr.hcl"))
if not hcl_files:
    print("  no packer templates found")
    sys.exit(2)

builder = pathlib.Path("scripts/build-image.sh")
if not builder.is_file():
    print("  scripts/build-image.sh is missing, so nothing supplies these")
    sys.exit(1)
script = builder.read_text()

# Written by build-image.sh rather than passed on the command line.
WRITTEN_BY_SCRIPT = {"ssh_public_key"}

missing = []
for f in hcl_files:
    for name, body in re.findall(r'variable "(\w+)" \{(.*?)\n\}', f.read_text(), re.S):
        # A real assignment, not the word "default" inside a description - which is how the
        # first version of this check reported every documented variable as fine.
        if re.search(r'^\s*default\s*=', body, re.M):
            continue
        if name in WRITTEN_BY_SCRIPT:
            continue
        if f'-var "{name}=' in script or f"-var {name}=" in script:
            continue
        missing.append((f, name))

for f, name in missing:
    print(f"  {f}: variable {name!r} has no default and build-image.sh does not pass it")
if not missing:
    print(f"  {len(hcl_files)} template(s) checked; every variable is defaulted, passed or written")
sys.exit(1 if missing else 0)
PYPACKER
  then ok 'the image build supplies every variable its template requires'
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then skip 'no packer templates - see above'
    else bad 'pass it in scripts/build-image.sh, or give the variable a default if one is correct'
    fi
  fi
else
  skip 'python3 missing, skipped'
fi

step "Cilium's pod CIDR agrees with every cluster's"
# THE OTHER HALF OF A PAIR THAT WAS ONLY CHECKED ON ONE SIDE. Lint already asserts that the two
# substrates' cluster.json files agree with each other about pod_cidr - and neither of them was
# ever compared with ansible/roles/cilium/files/cilium-values.yaml, which is the file that
# actually tells the Cilium operator which addresses to hand out.
#
# A disagreement here is not an error anywhere. The operator allocates per-node ranges out of
# its own pool, kubeadm tells kube-controller-manager about a different one, and pods come up
# with addresses nothing routes to - which presents as a CNI that installed cleanly and a
# DaemonSet that never becomes available.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYCIDR'
import json, pathlib, sys, yaml

values = yaml.safe_load(
    pathlib.Path("ansible/roles/cilium/files/cilium-values.yaml").read_text())
pool = values["ipam"]["operator"]["clusterPoolIPv4PodCIDRList"]

bad = False
for cfg in sorted(pathlib.Path("clusters").glob("*/*.json")):
    data = json.loads(cfg.read_text())
    # on-prem keeps it under a different key than the cloud substrates do; read both rather
    # than assuming, and say so when a file simply has no pod CIDR to check.
    cidr = (data.get("kubernetes", {}).get("pod_cidr")
            or data.get("networking", {}).get("pod_cidr"))
    if cidr is None:
        continue
    if cidr not in pool:
        print(f"  {cfg}: pod_cidr {cidr} is not in Cilium's pool {pool}")
        bad = True
    else:
        print(f"  {cfg.parent.name}: {cidr}")

if not any(True for _ in pathlib.Path("clusters").glob("*/*.json")):
    print("  no cluster configs found to compare against")
    sys.exit(2)
sys.exit(1 if bad else 0)
PYCIDR
  then ok "every cluster's pod CIDR is inside the pool cilium-values.yaml hands out"
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then skip 'nothing to compare - see above'
    else bad 'the CNI and kubeadm must agree about the pod CIDR, or pods get unroutable addresses'
    fi
  fi
else
  skip 'python3 missing, skipped'
fi

step 'The two kubeadm inventories define the same variables'
# THIS IS THE CHECK THAT SHOULD HAVE EXISTED BEFORE MODULE 09 WAS BUILT, and it is written after
# three consecutive failures of the same shape on 2026-11-05: `kube_context`, then (found by
# inspection beside it) `argocd_kubeconfig` pointing at an unreachable file, then
# `gateway_api_bundle`. Each one cost a full playbook run against a billing cluster to discover,
# and each was a variable ansible/inventory/nodes.py defines that ansible/inventory/aws.py did not.
#
# ansible/playbooks/cluster.yml runs the SAME eight roles against both substrates - that is the
# whole premise of Module 09 - so a variable one inventory supplies and the other does not is a
# role that works on one and fails on the other. Ansible finds that at the task, mid-run.
#
# WHY A SET DIFFERENCE RATHER THAN SCANNING THE ROLES for every `{{ name }}` they read: the
# scanning version was written first and abandoned. It cannot tell a variable from a Jinja filter,
# a loop variable, or prose inside a comment block, and - the part that makes it useless here - it
# cannot tell a REQUIRED variable from one guarded by `| default()`. `kube_server` is deliberately
# absent on-prem, and a check that flags it is a check that gets ignored. This one compares two
# things that are supposed to be equal, and names the exceptions explicitly below.
#
# A new asymmetry fails here and the fix is one of two lines: define it in the other inventory, or
# add it to SUBSTRATE_ONLY with the reason. Both are deliberate acts, which is the point.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PYINV'
import json, os, subprocess, sys

# Variables that SHOULD exist on one substrate only, each with the reason it cannot be shared.
SUBSTRATE_ONLY = {
    "ansible_ssh_common_args":
        "aws: a fresh EC2 instance has a host key nothing has seen, at an address reused across "
        "sessions - the libvirt VMs persist, so strict checking is correct there",
    "extra_cert_sans":
        "aws: the control plane's public IP must be in the API server certificate, because "
        "kubectl runs outside the VPC. On-prem one address serves both",
    "kube_server":
        "aws: ~/.kube/config must name the public address while controlPlaneEndpoint stays "
        "private. Guarded by | default() in the control_plane role, so on-prem needs no value",
}

def load(script):
    out = subprocess.run([script, "--list"], capture_output=True, text=True)
    if out.returncode != 0:
        # THREE OUTCOMES, not two (ADR-0003). The AWS inventory reads Terraform state and exits
        # non-zero when the substrate is not built, which is the normal case for a lint run on a
        # laptop. That is "I could not look", and it is not a failure.
        return None, (out.stderr or "").strip().splitlines()[:1]
    try:
        return set(json.loads(out.stdout)["all"]["vars"]), None
    except (json.JSONDecodeError, KeyError) as e:
        return None, [f"did not return the expected JSON: {e}"]

onprem, e1 = load("ansible/inventory/nodes.py")
aws, e2 = load("ansible/inventory/aws.py")

if onprem is None:
    print(f"  cannot compare: nodes.py did not list ({e1[0] if e1 else 'no error text'})")
    sys.exit(2)
if aws is None:
    # Fall back to reading the literal keys out of the source, which is what the seam check
    # already does for this same inventory and this same reason.
    # ONLY the dict that is the value of a "vars" key - not every dict in the file. Taking all
    # of them pulls in _meta, children, hosts and every hostvar name, and the check then fails
    # on its own scaffolding, which is how it first behaved.
    import ast, pathlib
    tree = ast.parse(pathlib.Path("ansible/inventory/aws.py").read_text())
    aws = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Dict):
            continue
        for key, value in zip(node.keys, node.values):
            if (isinstance(key, ast.Constant) and key.value == "vars"
                    and isinstance(value, ast.Dict)):
                aws |= {
                    k.value for k in value.keys
                    if isinstance(k, ast.Constant) and isinstance(k.value, str)
                }
    if not aws:
        print("  aws.py: could not find an `all.vars` dict in the source either")
        sys.exit(2)
    print("  aws.py: read from source - it cannot --list without its substrate built")

missing = sorted(onprem - aws - set(SUBSTRATE_ONLY))
extra = sorted(aws - onprem - set(SUBSTRATE_ONLY))

for name in missing:
    print(f"  ansible/inventory/aws.py does not define {name!r}, which nodes.py does")
    print(f"    cluster.yml runs the same roles on both, so a role reading it fails mid-run on AWS")
for name in extra:
    print(f"  ansible/inventory/nodes.py does not define {name!r}, which aws.py does")
    print(f"    define it there too, or add it to SUBSTRATE_ONLY in scripts/lint.sh with the reason")

sys.exit(1 if (missing or extra) else 0)
PYINV
  then ok 'both kubeadm inventories define the same variables, bar the three recorded exceptions'
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then skip 'could not list an inventory - see above'
    else bad 'define the variable in both inventories, or record why it belongs to one'
    fi
  fi
else
  skip 'python3 missing, skipped'
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