#!/usr/bin/env bash
# Seal the image: remove everything that makes this machine THIS machine.
#
# A clone that keeps its parent's machine-id will collide on DHCP leases, confuse systemd
# journal identification and, on some setups, get the same IP as its sibling. A clone that
# keeps its parent's SSH host keys is indistinguishable from it to any client. Both are
# silent problems that surface hours later as something else entirely.
set -euxo pipefail

apt-get -y autoremove --purge
apt-get -y clean

# machine identity
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# SSH host keys - regenerated on first boot by the ssh service
rm -f /etc/ssh/ssh_host_*

# cloud-init: forget this boot so clones re-run first-boot logic
cloud-init clean --logs --seed || true
rm -f /etc/netplan/50-cloud-init.yaml || true

# logs, history, caches
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/* /var/tmp/*
rm -f /root/.bash_history /home/*/.bash_history
rm -f /etc/udev/rules.d/70-persistent-net.rules

sync
echo "image sealed"
