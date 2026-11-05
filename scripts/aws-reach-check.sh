#!/usr/bin/env bash
# Does the security group still allow THIS workstation to reach the nodes?
#
# WHY THIS EXISTS. On 2026-11-05 all three nodes stopped answering SSH mid-session and the
# playbook said, five minutes later:
#
#   timed out waiting for ping module test: ... ssh: connect to host 13.203.210.72 port 22:
#   Connection timed out ... Make sure this host can be reached over ssh
#
# That message is identical for two causes with completely different answers:
#
#   the workstation's public address changed   -> `make aws-up` updates two rules in place,
#                                                 no node is touched, SSH works at once
#   the instance is gone (spot reclaimed)      -> the address in Terraform STATE points at
#                                                 nothing, and the node must be rebuilt
#
# This script answers the first one, which is the common one and the cheap one. It needs NO AWS
# CREDENTIALS: `admin_cidr` is a Terraform output and the state is local, so the whole check is
# one HTTPS call to AWS's own echo service and an address comparison.
#
# THREE OUTCOMES, per ADR-0003 - and here the third is the one that matters most, because this
# runs in front of a playbook that would otherwise work. A check that cannot look must not be
# able to stop the build.
#
#   0  the address is inside admin_cidr      - SSH should work; look elsewhere
#   1  the address is NOT inside admin_cidr  - this IS the cause, and the fix is printed
#   2  could not determine                   - says why, and the caller proceeds
set -uo pipefail

c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
TF_DIR="${TF_DIR:-terraform/aws}"

note() { printf '%s%s%s\n' "$c_dim" "$1" "$c_off"; }

command -v terraform >/dev/null 2>&1 || {
  note "terraform is not on PATH, so admin_cidr cannot be read - skipping the reachability check"
  exit 2
}

allowed=$(cd "$TF_DIR" && terraform output -raw admin_cidr 2>/dev/null)
if [[ -z "$allowed" ]]; then
  note "no admin_cidr in the Terraform state - nothing has been built here yet, or the state is elsewhere"
  exit 2
fi

# AWS's own echo service, the same one terraform/aws/variables.tf uses to DETECT the address -
# so the two readings are comparable by construction rather than by coincidence.
mine=$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
if [[ -z "$mine" ]]; then
  note "could not reach checkip.amazonaws.com, so this workstation's public address is unknown"
  note "that is not evidence either way - proceeding"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  note "python3 missing, so the address cannot be compared with the CIDR - proceeding"
  exit 2
fi

inside=$(python3 - "$mine" "$allowed" <<'PY'
import ipaddress, sys
try:
    print("yes" if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else "no")
except ValueError as e:
    print(f"error {e}")
PY
)

case "$inside" in
  yes)
    printf '%s[ ok ]%s this workstation (%s) is inside the allowed %s\n' \
      "$c_ok" "$c_off" "$mine" "$allowed"
    exit 0
    ;;
  no)
    printf '\n%sthe security group does not allow this workstation%s\n\n' "$c_err" "$c_off"
    printf '  this workstation is now   %s\n' "$mine"
    printf '  the rules still allow     %s\n\n' "$allowed"
    printf 'SSH and the API server are open to ONE address, detected when the nodes were built.\n'
    printf 'Your connection has been renumbered since. The nodes are fine and running.\n\n'
    printf '  make aws-up\n\n'
    printf '%sThe plan will show two aws_vpc_security_group_ingress_rule resources updated in\n' "$c_dim"
    printf 'place. No instance is replaced. If it proposes anything else, read it before\n'
    printf 'approving.%s\n\n' "$c_off"
    exit 1
    ;;
  *)
    note "could not compare $mine with $allowed ($inside) - proceeding"
    exit 2
    ;;
esac
