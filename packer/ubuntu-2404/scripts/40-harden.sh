#!/usr/bin/env bash
# Baseline hardening. Modest and reversible - this is a lab, not a bastion.
set -euxo pipefail
: "${SSH_USERNAME:=sagar}"

cat > /etc/ssh/sshd_config.d/10-platform.conf <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
SSHD

sshd -t   # never reload a config that does not parse
