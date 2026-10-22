#!/usr/bin/env bash
# Copy the kubeadm config from Git to the control plane, then validate it THERE.
#
#   make onprem-kubeadm-config
#
# This exists because the alternative - pasting a 50-line heredoc into an SSH session -
# silently truncates when the terminal wraps, and `kubeadm config validate` will happily
# say "ok" to a truncated file: it checks that the fields present are correct, not that
# you included the ones you meant to. A file in Git, copied over a pipe, cannot do that.
#
# It also checks that the config agrees with nodes.json, because two files holding the
# same CIDR is two chances to be wrong.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/clusters/onprem/nodes.json"
SRC="$REPO_ROOT/clusters/onprem/kubeadm/init.yaml"
DEST=/etc/kubernetes/kubeadm/init.yaml

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

[[ -f "$SRC" ]] || die "missing $SRC"

user=$(jq -r '.ssh.username' "$CONFIG")
cp_name=$(jq -r '.nodes[]|select(.role=="control-plane")|.name' "$CONFIG")
cp_addr=$(jq -r '.nodes[]|select(.role=="control-plane")|.address' "$CONFIG")
pod_cidr=$(jq -r '.kubernetes.pod_cidr' "$CONFIG")
svc_cidr=$(jq -r '.kubernetes.service_cidr' "$CONFIG")

# ---- the two files must agree. One source of truth, checked rather than hoped for.
step 'Checking the config against nodes.json'
for pair in "podSubnet:$pod_cidr" "serviceSubnet:$svc_cidr" \
            "advertiseAddress:$cp_addr" "name:$cp_name"; do
  key=${pair%%:*}; val=${pair#*:}
  grep -qE "^[[:space:]]*${key}:[[:space:]]*\"?${val}\"?[[:space:]]*$" "$SRC" \
    || die "$key in kubeadm/init.yaml does not match nodes.json ($val)"
done
ok "podSubnet $pod_cidr, serviceSubnet $svc_cidr, $cp_name at $cp_addr"

# ---- the installed kubeadm must match the pinned version
step "Checking the pinned version against $cp_name"
remote_ver=$(ssh -o StrictHostKeyChecking=accept-new "$user@$cp_addr" 'kubeadm version -o short')
pinned=$(grep -oP '^kubernetesVersion:\s*\K\S+' "$SRC")
[[ "$remote_ver" == "$pinned" ]] \
  || die "config pins $pinned but $cp_name has kubeadm $remote_ver. Update kubernetesVersion."
ok "both $pinned"

step "Copying to $cp_name:$DEST"
ssh "$user@$cp_addr" "sudo mkdir -p $(dirname $DEST)"
# Piped through cat, not scp to /tmp then moved: one hop, no intermediate copy to forget.
ssh "$user@$cp_addr" "sudo tee $DEST >/dev/null" < "$SRC"

step 'Verifying what actually landed'
local_sum=$(sha256sum < "$SRC" | cut -d' ' -f1)
remote_sum=$(ssh "$user@$cp_addr" "sudo sha256sum < $DEST" | cut -d' ' -f1)
[[ "$local_sum" == "$remote_sum" ]] || die "checksum mismatch - the copy is not identical"
ok "sha256 matches: ${local_sum:0:16}..."

# Four documents, and all four must be there. This is the check that the mangled
# paste would have failed while `kubeadm config validate` said ok.
kinds=$(ssh "$user@$cp_addr" "sudo grep -c '^kind:' $DEST")
[[ "$kinds" == "4" ]] || die "expected 4 documents (Init, Cluster, Kubelet, KubeProxy), found $kinds"
ok "4 documents present"

step 'kubeadm config validate'
ssh "$user@$cp_addr" "sudo kubeadm config validate --config $DEST"

echo
ok "Ready. Next, on $cp_name:"
echo "    sudo kubeadm init --config $DEST | tee ~/kubeadm-init.log"
