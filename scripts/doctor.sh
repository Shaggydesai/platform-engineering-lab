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

echo "Virtualisation (ADR-0006)"
if [ -e /dev/kvm ]; then
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s present and writable\n' "/dev/kvm"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s present but not writable - run: sudo usermod -aG kvm,libvirt $USER, then a new login shell\n' "/dev/kvm"; ((fail++))
  fi
else
  printf '  \033[31m[fail]\033[0m %-16s missing - nested virtualisation is off. See ADR-0006.\n' "/dev/kvm"; ((fail++))
fi
if command -v virsh >/dev/null 2>&1; then
  if virsh -c qemu:///system list >/dev/null 2>&1; then
    printf '  \033[32m[ ok ]\033[0m %-16s qemu:///system reachable\n' "libvirt"; ((ok++))
    if virsh -c qemu:///system pool-info default >/dev/null 2>&1; then
      printf '  \033[32m[ ok ]\033[0m %-16s default pool present\n' "storage pool"; ((ok++))
    else
      printf '  \033[31m[fail]\033[0m %-16s default pool missing - run: make tools\n' "storage pool"; ((fail++))
    fi
  else
    printf '  \033[31m[fail]\033[0m %-16s cannot reach qemu:///system - are you in the libvirt group? New login shell needed.\n' "libvirt"; ((fail++))
  fi
else
  printf '  \033[33m[warn]\033[0m %-16s not installed - run: make tools\n' "virsh"; ((warn++))
fi
# The three nodes need 20 GB; WSL defaults to half of host RAM.
mem_gb=$(free -g | awk '/Mem:/ {print $2}')
need_gb=$(( $(jq '[.nodes[].memory_mb] | add' clusters/onprem/nodes.json 2>/dev/null || echo 20480) / 1024 ))
if [ "$mem_gb" -ge $(( need_gb + 4 )) ]; then
  printf '  \033[32m[ ok ]\033[0m %-16s %sGB available, nodes need %sGB\n' "WSL memory" "$mem_gb" "$need_gb"; ((ok++))
else
  printf '  \033[31m[fail]\033[0m %-16s %sGB available, nodes need %sGB + headroom. Set memory=26GB in .wslconfig, then wsl --shutdown.\n' "WSL memory" "$mem_gb" "$need_gb"; ((fail++))
fi

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
  # WSL regenerates /etc/hosts on every start unless told not to, which would silently
  # delete the node entries 'make hosts' writes - and then helm and kubectl stop being
  # able to resolve the control plane, for reasons that look nothing like the cause.
  if grep -qE '^\s*generateHosts\s*=\s*false' /etc/wsl.conf 2>/dev/null; then
    printf '  \033[32m[ ok ]\033[0m %-16s generateHosts=false, /etc/hosts is ours\n' "wsl.conf"; ((ok++))
  else
    printf '  \033[33m[warn]\033[0m %-16s WSL will rewrite /etc/hosts on next start - run: make hosts\n' "wsl.conf"; ((warn++))
  fi
else
  printf '  \033[33m[warn]\033[0m %-16s not under WSL - see ADR-0005\n' "WSL"; ((warn++))
fi

echo
echo "Cluster reachability"
# The kubeconfig and the Cilium values both reach the API server by NAME, because
# controlPlaneEndpoint is deliberately a name (ADR-0002). The nodes resolve each other
# from cloud-init's /etc/hosts; this workstation needs the same entries.
if [ -f clusters/onprem/nodes.json ] && command -v jq >/dev/null 2>&1; then
  _dom=$(jq -r '.network.domain' clusters/onprem/nodes.json)
  _unresolved=""
  for _n in $(jq -r '.nodes[].name' clusters/onprem/nodes.json); do
    getent hosts "$_n.$_dom" >/dev/null 2>&1 || _unresolved="$_unresolved $_n.$_dom"
  done
  if [ -z "$_unresolved" ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s all node names resolve\n' "node DNS"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s cannot resolve:%s - run: make hosts\n' "node DNS" "$_unresolved"; ((fail++))
  fi
fi

echo
echo "Repository hygiene"
if git -C . rev-parse >/dev/null 2>&1; then
  if [ -f .gitattributes ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s present\n' ".gitattributes"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s missing - CRLF/BOM bugs incoming\n' ".gitattributes"; ((fail++))
  fi
  # From Module 04 onward, committing is how the cluster is changed. An unset identity fails
  # at `git commit` with "Author identity unknown", which is a confusing place to discover it -
  # you have already made the edit and are watching for a sync that will never come.
  _gname=$(git config user.name 2>/dev/null || true)
  _gmail=$(git config user.email 2>/dev/null || true)
  if [ -n "$_gname" ] && [ -n "$_gmail" ]; then
    printf '  \033[32m[ ok ]\033[0m %-16s %s <%s>\n' "git identity" "$_gname" "$_gmail"; ((ok++))
  else
    printf '  \033[31m[fail]\033[0m %-16s unset - you cannot commit, and committing is how the cluster changes now\n' "git identity"
    printf '         %s\n' 'git config --global user.name "..."; git config --global user.email "..."'; ((fail++))
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
