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

# ufw off, explicitly and permanently.
#
# Ubuntu's cloud image ships ufw installed but inactive, so this is usually a no-op - and
# that "usually" is the problem. An active host firewall is one of the nastiest things to
# debug in a Kubernetes cluster, because it does not fail cleanly: the API server answers,
# pods start, and then some traffic silently disappears depending on which node a pod
# landed on. The cluster appears to work and intermittently does not.
#
# Kubernetes expects to own the host's packet filtering. kube-proxy and Cilium both write
# their own rules, and a second firewall with its own default-deny policy fights them.
# Being explicit here means the image cannot drift into having one.
#
# In a real environment you would keep a firewall and open the ports Kubernetes documents.
# For a lab on an isolated NAT network behind a laptop, the complexity buys nothing.
systemctl disable --now ufw 2>/dev/null || true
ufw --force disable 2>/dev/null || true

# Boot to multi-user, not graphical. There is no display and no display manager, so
# graphical.target just pulls in extra units and a little more boot time for nothing.
systemctl set-default multi-user.target
