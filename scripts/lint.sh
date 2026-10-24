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
