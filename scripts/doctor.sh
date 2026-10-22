#!/usr/bin/env bash
# Checks the workstation has what the project needs. Run: make doctor
set -uo pipefail

ok=0; warn=0; fail=0
version_of() { # tools disagree about how to report their version
  case "$1" in
    kubectl) kubectl version --client 2>/dev/null | head -1 ;;
    helm)    helm version --short 2>/dev/null ;;
    argocd)  argocd version --client --short 2>/dev/null ;;
    aws)     aws --version 2>&1 ;;
    *)       "$1" --version 2>&1 | head -1 ;;
  esac
}

check() { # name  command  required(yes|no)  hint
  local name="$1" cmd="$2" required="$3" hint="${4:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local v; v=$(version_of "$cmd" | head -1 | cut -c1-60)
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

echo "Workstation"
if grep -qi microsoft /proc/version 2>/dev/null; then
  printf '  \033[32m[ ok ]\033[0m %-16s %s\n' "WSL" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}")"; ((ok++))
  case "$PWD" in
    /mnt/*) printf '  \033[31m[fail]\033[0m %-16s repo is on %s - clone it inside WSL (~/) instead. See ADR-0005.\n' "repo location" "$PWD"; ((fail++)) ;;
    *)      printf '  \033[32m[ ok ]\033[0m %-16s %s (native WSL filesystem)\n' "repo location" "$PWD"; ((ok++)) ;;
  esac
  VMRUN=""
  for p in "/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" \
           "/mnt/c/Program Files/VMware/VMware Workstation/vmrun.exe"; do
    [ -x "$p" ] && { VMRUN="$p"; break; }
  done
  if [ -n "$VMRUN" ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s %s\n' "vmrun.exe" "$("$VMRUN" 2>&1 | head -1 | cut -c1-44)"; ((ok++))
  else
    printf '  \033[33m[warn]\033[0m %-16s not found - is VMware Workstation installed?\n' "vmrun.exe"
    printf '         %s\n' "find it with:  ls -d /mnt/c/Program*/VMware*/VMware*"; ((warn++))
  fi
else
  printf '  \033[33m[warn]\033[0m %-16s not under WSL - see ADR-0005\n' "WSL"; ((warn++))
fi

echo
echo "Repository hygiene"
if git -C . rev-parse >/dev/null 2>&1; then
  if [ -f .gitattributes ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s present\n' ".gitattributes"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s missing - CRLF/BOM bugs incoming\n' ".gitattributes"; ((fail++))
  fi
  # .ps1 and .bat are declared eol=crlf in .gitattributes, so CRLF there is correct.
  bad_crlf=$(git grep -lI $'\r$' -- . 2>/dev/null | grep -vE '\.(ps1|bat)$' || true)
  if [ -n "$bad_crlf" ]; then
    printf '  \033[33m[warn]\033[0m %-16s CRLF in: %s\n' "line endings" "$(echo "$bad_crlf" | tr '\n' ' ')"; ((warn++))
  else
    printf '  \033[32m[ ok ]\033[0m %-16s correct (CRLF only where .gitattributes asks for it)\n' "line endings"; ((ok++))
  fi
fi

echo
echo "  $ok ok, $warn warnings, $fail failures"
[ "$fail" -eq 0 ] || { echo "  Fix the failures before Module 01."; exit 1; }
