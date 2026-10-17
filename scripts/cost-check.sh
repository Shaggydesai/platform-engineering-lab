#!/usr/bin/env bash
# Fails if anything billable is still running. Run at the END of every cloud session.
# Module 08/09 extend this; it is deliberately noisy rather than clever.
set -uo pipefail
found=0

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
else
  echo "AWS: cli not configured, skipped"
fi

if command -v gcloud >/dev/null 2>&1 && gcloud config get-value project >/dev/null 2>&1; then
  echo "GCP"
  c=$(gcloud container clusters list --format='value(name,location)' 2>/dev/null)
  i=$(gcloud compute instances list --format='value(name,zone)' 2>/dev/null)
  d=$(gcloud compute disks list --filter='-users:*' --format='value(name,zone)' 2>/dev/null)
  f=$(gcloud compute forwarding-rules list --format='value(name,region)' 2>/dev/null)
  [ -n "$c" ] && { echo "  clusters:"; echo "$c" | sed 's/^/    /'; found=1; }
  [ -n "$i" ] && { echo "  instances:"; echo "$i" | sed 's/^/    /'; found=1; }
  [ -n "$d" ] && { echo "  unattached disks:"; echo "$d" | sed 's/^/    /'; found=1; }
  [ -n "$f" ] && { echo "  forwarding rules (load balancers):"; echo "$f" | sed 's/^/    /'; found=1; }
  [ -z "$c$i$d$f" ] && echo "  clean"
else
  echo "GCP: gcloud not configured, skipped"
fi

echo
if [ "$found" -ne 0 ]; then
  echo "Billable resources are still running. Run 'make down ENV=...' or delete them by hand."
  exit 1
fi
echo "Nothing billable is running."
