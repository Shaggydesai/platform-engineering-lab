#!/usr/bin/env bash
# The installer reboots into a machine whose cloud-init is still finishing. Running apt before
# it settles produces lock errors that look like network failures.
set -euxo pipefail
cloud-init status --wait || true
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo "waiting for dpkg lock"; sleep 5; done
