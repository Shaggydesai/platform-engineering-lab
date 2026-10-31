#!/usr/bin/env bash
# Fails if anything billable is still running. Run at the END of every cloud session.
# Module 08/09 extend this; it is deliberately noisy rather than clever.
set -uo pipefail
found=0
# Which providers were ACTUALLY interrogated. Without this, a workstation with no cloud CLI
# configured printed "Nothing billable is running" and exited 0 - a green light from a check that
# ran nothing, which is precisely the reassurance that ends a session with a cluster still up.
# "I could not look" and "I looked and it is clean" are different answers and this script used to
# give the same one for both.
checked=0
skipped=""

if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS"
  for r in ap-south-1 us-east-1; do
    inst=$(aws ec2 describe-instances --region "$r" \
      --filters Name=instance-state-name,Values=running,pending \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
    lbs=$(aws elbv2 describe-load-balancers --region "$r" \
      --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)
    vols=$(aws ec2 describe-volumes --region "$r" \
      --query 'Volumes[?State==`available`].VolumeId' --output text 2>/dev/null)
    nats=$(aws ec2 describe-nat-gateways --region "$r" \
      --query 'NatGateways[?State==`available`].NatGatewayId' --output text 2>/dev/null)
    eks=$(aws eks list-clusters --region "$r" --query 'clusters' --output text 2>/dev/null)
    for pair in "instances:$inst" "load-balancers:$lbs" "unattached-volumes:$vols" \
                "nat-gateways:$nats" "eks-clusters:$eks"; do
      k=${pair%%:*}; v=${pair#*:}
      [ -n "$v" ] && [ "$v" != "None" ] && { echo "  [$r] $k: $v"; found=1; }
    done
  done
  [ "$found" -eq 0 ] && echo "  clean"
  checked=$((checked + 1))
else
  echo "AWS: cli not configured, skipped"
  skipped="$skipped AWS"
fi

# EVERY project this account can see, not just the configured one.
#
# The first version scanned `gcloud config get-value project` alone, and the evidence that this
# was wrong arrived before anything had been built: the billing account carried ₹591 of spend and
# two budgets nobody here created, one named "(terraform)". Resources from an earlier state can
# be in a project nobody has run `gcloud config set project` for since - and a cost check that
# only looks where you are standing is a cost check that agrees with you.
#
# The budget guardrail is scoped to the whole billing account for the same reason (ADR-0019).
if command -v gcloud >/dev/null 2>&1 \
   && gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  echo "GCP"
  projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null)
  if [ -z "$projects" ]; then
    echo "  no projects visible to this account"
  fi
  for P in $projects; do
    HDR=""
    report() { # $1 label, $2 value. Sets the globals HDR and found - never call it in $( ).
      [ -n "$2" ] || return 0
      if [ -z "$HDR" ]; then echo "  [$P]"; HDR=1; fi
      echo "    $1:"; printf '%s\n' "$2" | sed 's/^/      /'
      found=1
    }
    report "clusters" \
      "$(gcloud container clusters list --project="$P" --format='value(name,location)' 2>/dev/null)"
    report "instances" \
      "$(gcloud compute instances list --project="$P" --format='value(name,zone,status)' 2>/dev/null)"
    report "unattached disks" \
      "$(gcloud compute disks list --project="$P" --filter='-users:*' --format='value(name,zone,sizeGb)' 2>/dev/null)"
    report "forwarding rules (load balancers)" \
      "$(gcloud compute forwarding-rules list --project="$P" --format='value(name,region)' 2>/dev/null)"
    # A RESERVED address that is not attached to anything is billed and is invisible in every
    # other listing here - the classic orphan, and more likely now that ADR-0019 puts external
    # IPs on the nodes deliberately.
    report "reserved addresses not in use" \
      "$(gcloud compute addresses list --project="$P" --filter='status!=IN_USE' --format='value(name,region,status)' 2>/dev/null)"
    report "snapshots" \
      "$(gcloud compute snapshots list --project="$P" --format='value(name,diskSizeGb)' 2>/dev/null)"
  done
  [ "$found" -eq 0 ] && echo "  clean across $(printf '%s\n' "$projects" | grep -c .) project(s)"
  checked=$((checked + 1))
else
  echo "GCP: gcloud not configured, skipped"
  skipped="$skipped GCP"
fi

echo
if [ "$found" -ne 0 ]; then
  echo "Billable resources are still running. Run 'make down ENV=...' or delete them by hand."
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  echo "NOTHING WAS CHECKED - neither cloud CLI is configured on this machine."
  echo
  echo "This is not a pass. If a cloud session was run from somewhere else, or the credentials"
  echo "have expired here, resources could be running and this script cannot see them."
  echo "  gcloud auth login && gcloud config set project <id>"
  echo "  aws configure"
  # 2, not 0 and not 1: UNKNOWN is neither a clean bill nor a detection, the same distinction
  # make gcp-guardrails-verify draws.
  exit 2
fi

if [ -n "$skipped" ]; then
  echo "Nothing billable in the provider(s) checked. NOT checked:$skipped"
  echo "That is a partial answer - say so out loud rather than reading it as all clear."
  exit 0
fi
echo "Nothing billable is running, in any project of either provider."
