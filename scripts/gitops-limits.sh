#!/usr/bin/env bash
# What resource limits does every container in every wrapper chart ACTUALLY end up with?
#
#   make gitops-limits
#
# A report. It changes nothing, it never fails the build, and it exists to answer one question
# that a values file cannot: did the `resources:` block I wrote land on the container I meant?
#
# WHY THIS EXISTS. Helm silently ignores a value path that does not exist. Set
# `webhook.resources` on a chart whose key is `admissionWebhooks.resources` and the result is a
# file that reads correctly, a render that succeeds, a deploy that works, and a container with no
# limits at all. Nothing anywhere reports it. That is the same shape as every other failure this
# repository has collected - Helm's exit code, the cilium-config ConfigMap, a digest comparison
# where both sides were empty - a check that confirms the REQUEST was recorded rather than that
# it took effect.
#
# External Secrets is what prompted it: three deployments, three separate values blocks, and no
# way to know from the values file whether the names are right.
#
# So: an UNBOUNDED row for a container whose chart values DO set resources means the value path
# is wrong. An UNBOUNDED row for a container nobody has set limits on is just a to-do.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENVIRONMENT="${1:-onprem}"

c_hdr=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

command -v helm >/dev/null || { echo "helm not installed - run: make tools" >&2; exit 1; }
command -v yq   >/dev/null || { echo "yq not installed - run: make tools" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq not installed - run: make tools" >&2; exit 1; }

printf '%s%-18s %-34s %-26s %-10s %-10s%s\n' \
  "$c_hdr" "CHART" "WORKLOAD" "CONTAINER" "CPU" "MEMORY" "$c_off"

unbounded=0
rows=0

for chart_dir in gitops/charts/*/; do
  chart=$(basename "$chart_dir")

  # Rendered by the same script `make gitops-render` and `make lint` use. A second copy of "how a
  # chart is rendered" is how two tools come to disagree about what is deployed.
  if ! rendered=$(bash scripts/gitops-render.sh "$chart" "$ENVIRONMENT" 2>/dev/null); then
    printf '%s%-18s %s%s\n' "$c_warn" "$chart" "did not render - make gitops-render CHART=$chart" "$c_off"
    continue
  fi

  # yq to JSON, then jq: a rendered chart is a multi-document stream and jq reads concatenated
  # documents natively. Templates that render to nothing produce a `null` document, which jq
  # indexes to null rather than erroring - so no filtering is needed for them.
  while IFS=$'\t' read -r workload container cpu mem; do
    [[ -z "${workload:-}" ]] && continue
    rows=$((rows + 1))
    if [[ "$cpu" == "-" && "$mem" == "-" ]]; then
      colour="$c_warn"; cpu="UNBOUNDED"; mem="UNBOUNDED"
      unbounded=$((unbounded + 1))
    elif [[ "$cpu" == "-" || "$mem" == "-" ]]; then
      # One of the two set is worth its own colour: a memory limit with no CPU limit is a
      # deliberate and common choice (CPU throttling hurts more than it helps), whereas a CPU
      # limit with no memory limit is almost always an oversight.
      colour="$c_dim"
    else
      colour="$c_ok"
    fi
    printf '%s%-18s %-34s %-26s %-10s %-10s%s\n' \
      "$colour" "$chart" "$workload" "$container" "$cpu" "$mem" "$c_off"
  done < <(printf '%s\n' "$rendered" | yq -o=json -I=0 '.' 2>/dev/null | jq -r '
      select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
      | (.kind + "/" + .metadata.name) as $w
      | .spec.template.spec as $pod
      | (($pod.containers // []) + ($pod.initContainers // []))[]
      | [ $w,
          .name,
          (.resources.limits.cpu // "-" | tostring),
          (.resources.limits.memory // "-" | tostring) ]
      | @tsv')
done

echo
if [[ "$rows" == 0 ]]; then
  printf '%sNo workloads found. If helm renders fine by hand, the parsing above is what broke -\n' "$c_warn"
  printf 'which happened twice this week in this repository'"'"'s own test tooling.%s\n' "$c_off"
  exit 0
fi

printf '%d container(s), %d unbounded.\n\n' "$rows" "$unbounded"
printf 'Read an UNBOUNDED row twice. If the chart'"'"'s values set resources for it, the value path\n'
printf 'is WRONG and Helm ignored it in silence - the whole reason this report exists. If nothing\n'
printf 'sets limits for it, it is an unbounded container and a node-level risk, which is a\n'
printf 'different problem with the same output.\n\n'
printf '%sRequests are not shown on purpose.%s Requests decide scheduling; limits decide whether one\n' "$c_dim" "$c_off"
printf 'component can take a node down. On three workers that also run the tenant, the second\n'
printf 'question is the one worth a report.\n'
