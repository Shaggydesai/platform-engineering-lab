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
# A listing that FAILED is not a listing that found nothing. Tracked separately so the verdict
# can say "I could not see everything" instead of "clean".
unknown=0
bucket_warn=0
# Secret Manager versions, summed across EVERY project rather than per project, because the free
# allowance is a quota on the billing account and not on a project. Six versions in one project
# and four in another is ten against a six-version allowance, and a per-project check would call
# both of them clean. Reported after the loop; the per-project lines above it are the detail.
#
# Said as an assumption rather than a fact: Google documents six free versions without being
# crisp about the scope in the place most people read. Summing is the conservative reading - it
# can warn early, which is the direction to be wrong in.
sm_grand=0
c_dim=$'\033[2m'; c_warn=$'\033[33m'; c_off=$'\033[0m'

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
if command -v gcloud >/dev/null 2>&1 \
   && gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  echo "GCP"

  # NEVER PROMPT. The first run of the multi-project version hung with no output after "GCP":
  # `gcloud compute instances list` against a project whose Compute API is disabled asks
  # "Would you like to enable and retry? (y/N)" - and stderr was being sent to /dev/null, so
  # gcloud sat waiting on stdin with the question invisible. A check that hangs silently is
  # worse than one that fails, because the only signal is that nothing is happening.
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1

  # Where to look for KMS keyrings, beyond "global". Best effort: if the file or jq is missing
  # the default in the loop below applies, and the script says which locations it searched.
  kms_region=$(jq -r '.region // empty' clusters/gcp/cluster.json 2>/dev/null)

  projects=$(timeout 60 gcloud projects list --format='value(projectId)' 2>/dev/null)
  if [ -z "$projects" ]; then
    echo "  no projects visible to this account"
    skipped="$skipped GCP-projects"
  fi

  P=""
  # stdout and stderr go to DIFFERENT places, and the first version merged them with 2>&1.
  # That produced a false alarm on the first real run: gcloud writes
  #
  #     WARNING: The following filter keys were not present in any resource : users
  #
  # to stderr, with exit code 0, when a --filter names a key no resource has - which is exactly
  # what happens when there are NO disks. The warning landed in the output, a non-empty output
  # means a finding, and an empty account reported "Billable resources are still running".
  #
  # A false alarm is the better direction to fail in than the false all-clear this script started
  # with, and it is still wrong in the way that matters most for a check nobody is forced to
  # read: it teaches you to ignore the output.
  ERRF=$(mktemp)
  trap 'rm -f "$ERRF"' EXIT

  # $1 = label, $2 = how to remove one of these, rest = gcloud arguments.
  #
  # The removal hint is part of the finding rather than something to look up afterwards. This
  # script exists to be read at the END of a session, by someone who wants the thing gone and
  # not a research task - and a resource whose delete command is one line away is a resource
  # that actually gets deleted.
  probe() {
    label=$1; hint=$2; shift 2
    : > "$ERRF"
    out=$(timeout 45 gcloud "$@" --project="$P" 2>"$ERRF"); rc=$?
    err=$(cat "$ERRF")
    if [ "$rc" -ne 0 ]; then
      case "$err" in
        # An API that was never enabled cannot have resources of that kind. That is a genuine
        # CLEAN answer for this listing, not an inability to check, and reporting it as unknown
        # would make every untouched project produce five scary lines.
        *"SERVICE_DISABLED"*|*"not enabled on project"*|*"has not been used in project"*)
          # Counted, not printed per listing: an untouched project disables five of these and
          # five dim lines apiece is noise that buries the one line that matters.
          api_off=$((api_off + 1))
          return 0 ;;
      esac
      # Anything else - a permission denial, a timeout, a network failure - is NOT clean. An
      # empty result from a failed call used to be indistinguishable from an empty account.
      printf '      %s%s: COULD NOT CHECK%s\n' "$c_warn" "$label" "$c_off"
      printf '%s\n' "$err" | head -2 | sed 's/^/          /'
      unknown=1
      return 0
    fi
    # rc is 0 here, so stderr holds warnings and nothing else. Only stdout - the resource list -
    # decides whether something was found.
    [ -n "$out" ] || return 0
    printf '      %s:\n' "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
    [ -n "$hint" ] && printf '        %sremove: %s%s\n' "$c_dim" "$hint" "$c_off"
    found=1
  }

  for P in $projects; do
    # Printed BEFORE probing, not lazily on the first finding: it is progress output for a step
    # that takes a few seconds per project, and it also records which projects were examined -
    # which is part of the answer, not decoration.
    echo "  [$P]"
    before_found=$found
    api_off=0
    probe "clusters" "gcloud container clusters delete NAME --location=LOC --project=$P" \
      container clusters list --format='value(name,location)'
    probe "instances" "gcloud compute instances delete NAME --zone=ZONE --project=$P" \
      compute instances list --format='value(name,zone,status)'
    probe "unattached disks" "gcloud compute disks delete NAME --zone=ZONE --project=$P" \
      compute disks list --filter='-users:*' --format='value(name,zone,sizeGb)'
    probe "forwarding rules (load balancers)" "gcloud compute forwarding-rules delete NAME --region=REGION --project=$P" \
      compute forwarding-rules list --format='value(name,region)'
    # A RESERVED address not attached to anything is billed and appears in no other listing
    # here - the classic orphan, and likelier now that ADR-0019 puts external IPs on the nodes.
    probe "reserved addresses not in use" "gcloud compute addresses delete NAME --region=REGION --project=$P" \
      compute addresses list --filter='status!=IN_USE' --format='value(name,region,status)'
    probe "snapshots" "gcloud compute snapshots delete NAME --project=$P" \
      compute snapshots list --format='value(name,diskSizeGb)'

    # ---- the ones this script was BLIND to until 2026-10-31 -------------------------------
    #
    # Added because the account owner named two leftovers from an earlier attempt that none of
    # the listings above can see: a KMS key for Vault auto-unseal, and a GCS bucket for Terraform
    # state. The check had been reporting "nothing billable" with both of them sitting there.
    #
    # A guardrail is only as wide as its list of resource types, and the list is the part nobody
    # revisits. This is the second thing today that was clean because it was not looking.

    # Storage is cheap and permanent, which is the bad combination: a few rupees a month, for
    # years, with nothing ever prompting you about it.
    b4=$found
    probe "storage buckets" "gcloud storage rm -r gs://NAME     # READ THE WARNING BELOW FIRST" \
      storage buckets list --format='value(name)'
    [ "$found" -ne "$b4" ] && bucket_warn=1

    # Artifact Registry is free to 0.5 GB and billed above it. Relevant soon either way: ADR-0019
    # parks "mirror the images here" as the ₹0 alternative to external IPs on nodes.
    probe "artifact registry repositories" "gcloud artifacts repositories delete NAME --location=LOC --project=$P" \
      artifacts repositories list --format='value(name,format,location)'

    # KMS is billed per ENABLED key version, about $0.06 each per month. Two things make it
    # awkward and both are worth knowing before you go looking:
    #
    #   - a keyring and a key can NEVER be deleted. Only key VERSIONS can be destroyed, and that
    #     is what stops the billing; the empty keyring stays forever and costs nothing.
    #   - keyrings are per-LOCATION, and there is no list-them-all. These are the locations this
    #     project would plausibly have used. If a key is somewhere else:
    #       for L in $(gcloud kms locations list --project=P --format='value(locationId)'); do
    #         gcloud kms keyrings list --location="$L" --project=P; done
    for L in global ${kms_region:-asia-south1}; do
      probe "KMS keyrings in $L" "destroy its key VERSIONS - the keyring itself cannot be deleted and is free" \
        kms keyrings list --location="$L" --format='value(name)'
    done

    # SECRET MANAGER, and this one cannot use `probe` - which is the interesting part.
    #
    # `probe` reports anything it finds as billable. A Secret Manager secret is NOT billable at
    # six enabled versions or fewer: that is the monthly free allowance, and ADR-0018's GCP
    # amendment deliberately put all six of ShopVerse's credentials in ONE secret as JSON so the
    # steady state is ONE version. Reporting it as a finding would be a false alarm, which this
    # script has produced before - it once counted two gcloud WARNING lines on stderr as
    # findings and declared a clean account billable.
    #
    # But leaving it out entirely is the OTHER failure this script has produced twice: it is
    # exactly as wide as the resource types someone remembered, and it reported "nothing
    # billable" with two buckets and a KMS keyring sitting there. The secret backend is the first
    # GCP resource in this repository that deliberately SURVIVES `make gcp-down`, so it is
    # precisely the kind of thing a session-end check must be able to see.
    #
    # So: COUNT, and report the count every time. Free today, visible always, a finding at seven.
    : > "$ERRF"
    sm_out=$(timeout 45 gcloud secrets list --project="$P" --format='value(name)' 2>"$ERRF"); sm_rc=$?
    sm_err=$(cat "$ERRF")
    if [ "$sm_rc" -ne 0 ]; then
      case "$sm_err" in
        *"SERVICE_DISABLED"*|*"not enabled on project"*|*"has not been used in project"*)
          api_off=$((api_off + 1)) ;;
        *)
          printf '      %ssecret manager: COULD NOT CHECK%s\n' "$c_warn" "$c_off"
          printf '%s\n' "$sm_err" | head -2 | sed 's/^/          /'
          unknown=1 ;;
      esac
    elif [ -n "$sm_out" ]; then
      # Strip any leading resource path. `gcloud secrets list --format='value(name)'` prints the
      # bare ID on some versions and projects/P/secrets/ID on others, and a wrong name here
      # would make every version count come back 0 - a zero that looks like good news.
      sm_total=0
      sm_detail=''
      for s in $(printf '%s\n' "$sm_out" | sed 's#.*/##'); do
        # grep -c . rather than wc -l: command substitution strips the trailing newline, so wc
        # counts N-1 and a two-version secret reports as one. That exact off-by-one appeared in
        # gcp-smoke.sh the same week and read like a real cluster symptom.
        n=$(timeout 45 gcloud secrets versions list "$s" --project="$P" \
              --filter='state:ENABLED' --format='value(name)' 2>/dev/null | grep -c . || true)
        sm_total=$((sm_total + n))
        sm_detail="$sm_detail $s=$n"
        sm_grand=$((sm_grand + n))
      done
      if [ "$sm_total" -gt 6 ]; then
        printf '      secret manager versions (%s enabled, SIX are free):\n' "$sm_total"
        printf '       %s\n' "$sm_detail"
        printf '        %sremove: gcloud secrets versions destroy N --secret=NAME --project=%s%s\n' \
          "$c_dim" "$P" "$c_off"
        printf '        %sDISABLING IS NOT ENOUGH - a disabled version still counts as active%s\n' \
          "$c_dim" "$c_off"
        found=1
      else
        printf '      %ssecret manager: %s of 6 free versions in use -%s%s\n' \
          "$c_dim" "$sm_total" "$sm_detail" "$c_off"
      fi
    fi
    [ "$api_off" -gt 0 ] && printf '      %s%s listing(s) skipped: that API is not enabled here, so nothing of the kind exists%s\n' \
      "$c_dim" "$api_off" "$c_off"
    [ "$found" -eq "$before_found" ] && printf '      %snothing billable%s\n' "$c_dim" "$c_off"
  done

  # The account-wide total, because the per-project lines cannot see it. Each project can be
  # within the allowance while the account is not.
  if [ "$sm_grand" -gt 6 ]; then
    printf '  %s%s Secret Manager versions across all projects, and SIX are free%s\n' \
      "$c_warn" "$sm_grand" "$c_off"
    printf '    The per-project lines above may each look fine - the allowance is a quota on the\n'
    printf '    BILLING ACCOUNT, so they add up. Destroy the versions you no longer need.\n'
    found=1
  fi
  checked=$((checked + 1))
else
  echo "GCP: gcloud not configured, skipped"
  skipped="$skipped GCP"
fi

echo
# The verdict, in strict order of severity. The order IS the logic: an earlier version put the
# "some providers were skipped" branch before the "some listings failed" one, so a permission
# denial printed its warning and then exited 0 - a pass, from a run that could not see part of
# the account.
#
#   1  something billable was found
#   2  nothing was found AND something could not be read   (UNKNOWN - not a pass)
#   0  nothing was found and everything asked was readable

if [ "$found" -ne 0 ]; then
  echo "Billable resources are still running. Each finding above carries its own remove command."
  if [ "$bucket_warn" -ne 0 ]; then
    echo
    echo "BEFORE DELETING ANY BUCKET - look inside it first:"
    echo "    gcloud storage ls gs://NAME/**"
    echo
    echo "A bucket holding *.tfstate is the RECORD of what some Terraform run created. Deleting"
    echo "the bucket does not delete those resources - it deletes the only thing that knows they"
    echo "exist, and they keep billing with nothing left to destroy them. If it holds state,"
    echo "run \`terraform destroy\` against it first, or copy the state down and inspect it:"
    echo "    gcloud storage cp gs://NAME/path/to/default.tfstate - | jq '.resources[].type'"
    echo
    echo "This matters here specifically: a budget named \"shopverse-lab (terraform)\" exists on"
    echo "the billing account, so some state file created it and may have created more."
  fi
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  echo "NOTHING WAS CHECKED - neither cloud CLI is configured on this machine."
  echo
  echo "This is not a pass. If a cloud session was run from somewhere else, or the credentials"
  echo "have expired here, resources could be running and this script cannot see them."
  echo "  gcloud auth login && gcloud config set project <id>"
  echo "  aws configure"
  exit 2
fi

if [ "$unknown" -ne 0 ]; then
  echo "Nothing billable FOUND - but a listing could not be read (marked COULD NOT CHECK above)."
  echo "That is not the same as clean: a failed listing and an empty one look identical here."
  echo "Fix the access and re-run before relying on this."
  exit 2
fi

if [ -n "$skipped" ]; then
  echo "Nothing billable in the provider(s) checked. NOT checked:$skipped"
  echo "A partial answer, said out loud rather than read as all clear."
  exit 0
fi

echo "Nothing billable is running, in any project of either provider."
