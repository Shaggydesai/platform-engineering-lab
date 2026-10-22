#!/usr/bin/env bash
# Baseline hardening. Modest and reversible - this is a lab, not a bastion.
set -euxo pipefail
: "${SSH_USERNAME:=sagar}"
: "${SSH_PUBLIC_KEY:=}"

if [ -n "$SSH_PUBLIC_KEY" ]; then
  install -d -m 700 -o "$SSH_USERNAME" -g "$SSH_USERNAME" "/home/$SSH_USERNAME/.ssh"
  echo "$SSH_PUBLIC_KEY" > "/home/$SSH_USERNAME/.ssh/authorized_keys"
  chmod 600 "/home/$SSH_USERNAME/.ssh/authorized_keys"
  chown "$SSH_USERNAME:$SSH_USERNAME" "/home/$SSH_USERNAME/.ssh/authorized_keys"

  # Only disable passwords when a key is actually present - otherwise you lock yourself out
  # of your own template, which is a genuinely annoying way to lose an afternoon.
  cat > /etc/ssh/sshd_config.d/10-platform.conf <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
SSHD
else
  cat > /etc/ssh/sshd_config.d/10-platform.conf <<'SSHD'
PermitRootLogin no
X11Forwarding no
SSHD
  echo "WARNING: no SSH_PUBLIC_KEY given - password auth left enabled."
fi

sshd -t   # never reload a config that does not parse
