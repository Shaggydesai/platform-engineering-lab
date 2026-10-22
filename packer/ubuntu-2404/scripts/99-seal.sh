#!/usr/bin/env bash
# Seal the image: remove everything that makes this machine THIS machine.
#
# A clone keeping its parent's machine-id collides on DHCP leases and confuses journald; one
# keeping its SSH host keys is indistinguishable from its parent to any client. Both surface
# hours later as something that looks unrelated.
#
# cloud-init itself STAYS - it is how each node receives its identity at boot. Only its state
# is cleared, so it runs fresh against the seed Terraform attaches.
set -euxo pipefail

apt-get -y autoremove --purge
apt-get -y clean

# cloud-init: forget this build entirely
cloud-init clean --logs --seed
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg \
      /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg \
      /etc/netplan/50-cloud-init.yaml

# machine identity
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# SSH host keys - regenerated on first boot
rm -f /etc/ssh/ssh_host_*

# the build-time user's authorized_keys: Terraform's cloud-init will set the real one
rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys

# logs, history, caches
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/* /var/tmp/*
rm -f /root/.bash_history /home/*/.bash_history

# zero free space so the qcow2 compresses well - cheap here, saves gigabytes on C:
fstrim -av || dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync
echo "image sealed"
