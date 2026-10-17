#!/usr/bin/env bash
# Checks the workstation has what the project needs. Run: make doctor
set -uo pipefail

ok=0; warn=0; fail=0
check() { # name  command  required(yes|no)  hint
  local name="$1" cmd="$2" required="$3" hint="${4:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local v; v=$("$cmd" --version 2>&1 | head -1 | cut -c1-60)
    printf '  \033[32m[ ok ]\033[0m %-16s %s\n' "$name" "$v"; ((ok++))
  elif [ "$required" = yes ]; then
    printf '  \033[31m[fail]\033[0m %-16s missing. %s\n' "$name" "$hint"; ((fail++))
  else
    printf '  \033[33m[warn]\033[0m %-16s missing (needed from a later module). %s\n' "$name" "$hint"; ((warn++))
  fi
}

echo "Core"
check git       git       yes  "https://git-scm.com"
check kubectl   kubectl   yes  "https://kubernetes.io/docs/tasks/tools/"
check helm      helm      yes  "https://helm.sh/docs/intro/install/  (note: Helm 4 is current)"

echo "Module 01-03"
check terraform terraform no   "https://developer.hashicorp.com/terraform/install"
check ansible   ansible   no   "pipx install ansible-core"
check packer    packer    no   "https://developer.hashicorp.com/packer/install"

echo "Module 04+"
check argocd    argocd    no   "https://argo-cd.readthedocs.io/en/stable/cli_installation/"
check yq        yq        no   "https://github.com/mikefarah/yq"
check jq        jq        no   "https://jqlang.github.io/jq/"

echo "Module 08-09"
check gcloud    gcloud    no   "https://cloud.google.com/sdk/docs/install"
check aws       aws       no   "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

echo
echo "Repository hygiene"
if git -C . rev-parse >/dev/null 2>&1; then
  if [ -f .gitattributes ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s present\n' ".gitattributes"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s missing - CRLF/BOM bugs incoming\n' ".gitattributes"; ((fail++))
  fi
  if git grep -lI $'\r$' -- . >/dev/null 2>&1; then
    printf '  \033[33m[warn]\033[0m %-16s CRLF found in tracked files\n' "line endings"; ((warn++))
  else
    printf '  \033[32m[ ok ]\033[0m %-16s no CRLF in tracked files\n' "line endings"; ((ok++))
  fi
fi

echo
echo "  $ok ok, $warn warnings, $fail failures"
[ "$fail" -eq 0 ] || { echo "  Fix the failures before Module 01."; exit 1; }
