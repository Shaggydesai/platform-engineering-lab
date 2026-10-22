#!/usr/bin/env bash
# Install the workstation toolchain inside WSL. Idempotent: skips whatever is already present.
#
#   ./scripts/install-tools.sh            # everything make doctor asks for
#   ./scripts/install-tools.sh jq yq      # just these
#
# Versions are pinned where a wrong version would matter and left floating where it would not.
set -euo pipefail

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_skip=$'\033[33m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok"   "$*" "$c_off"; }
skip() { printf '    %s%s%s\n' "$c_skip" "$*" "$c_off"; }

ARCH=amd64
WANT=("$@")
want() {
  [[ ${#WANT[@]} -eq 0 ]] && return 0
  local t; for t in "${WANT[@]}"; do [[ "$t" == "$1" ]] && return 0; done; return 1
}
have() { command -v "$1" >/dev/null 2>&1; }

sudo -v

# ---------------------------------------------------------------- apt basics

if want apt; then
  step 'Base packages'
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    curl wget git make unzip gnupg ca-certificates lsb-release \
    jq python3-pip pipx bash-completion
  ok 'installed'
fi

# ---------------------------------------------------------------- HashiCorp: terraform, packer

if want packer || want terraform; then
  if ! have packer || ! have terraform; then
    step 'HashiCorp repository (terraform, packer)'
    if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
      wget -qO- https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq packer terraform
    ok "packer $(packer --version 2>/dev/null)"
  else
    skip 'terraform and packer already present'
  fi
fi

# ---------------------------------------------------------------- yq

if want yq; then
  if have yq; then skip "yq already present: $(yq --version)"; else
    step 'yq'
    YQ_VERSION=v4.44.3
    sudo wget -qO /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
    sudo chmod +x /usr/local/bin/yq
    ok "$(yq --version)"
  fi
fi

# ---------------------------------------------------------------- ansible

if want ansible; then
  if have ansible; then skip "ansible already present: $(ansible --version | head -1)"; else
    step 'ansible-core (via pipx, so it does not fight the system python)'
    pipx install --quiet ansible-core
    pipx inject --quiet ansible-core kubernetes jmespath   # needed by kubernetes.core later
    pipx ensurepath >/dev/null
    export PATH="$HOME/.local/bin:$PATH"
    ok "$(ansible --version | head -1)"
    echo '    note: open a new shell, or run: export PATH="$HOME/.local/bin:$PATH"'
  fi
fi

# ---------------------------------------------------------------- argocd cli

if want argocd; then
  if have argocd; then skip "argocd already present: $(argocd version --client --short 2>/dev/null)"; else
    step 'argocd CLI'
    ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
      | jq -r .tag_name)
    sudo curl -fsSL -o /usr/local/bin/argocd \
      "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}"
    sudo chmod +x /usr/local/bin/argocd
    ok "$(argocd version --client --short 2>/dev/null)"
  fi
fi

# ---------------------------------------------------------------- aws cli v2

if want aws; then
  if have aws; then skip "aws already present: $(aws --version 2>&1)"; else
    step 'AWS CLI v2'
    tmp=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$tmp/awscliv2.zip"
    unzip -q "$tmp/awscliv2.zip" -d "$tmp"
    sudo "$tmp/aws/install" --update >/dev/null
    rm -rf "$tmp"
    ok "$(aws --version 2>&1)"
  fi
fi

# ---------------------------------------------------------------- shell quality of life

if want completion; then
  step 'Shell completion'
  {
    echo 'source <(kubectl completion bash)'
    echo 'alias k=kubectl'
    echo 'complete -o default -F __start_kubectl k'
    echo 'source <(helm completion bash 2>/dev/null)'
  } > "$HOME/.kube_completion"
  grep -q 'kube_completion' "$HOME/.bashrc" 2>/dev/null \
    || echo '[ -f ~/.kube_completion ] && source ~/.kube_completion' >> "$HOME/.bashrc"
  ok 'written to ~/.kube_completion and sourced from ~/.bashrc'
fi

echo
step 'Now run: make doctor'
