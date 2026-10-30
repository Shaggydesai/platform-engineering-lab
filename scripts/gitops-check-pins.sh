#!/usr/bin/env bash
# Compare every wrapper chart's pinned dependency version against what its repository offers.
#
#   make gitops-check-pins
#
# This exists because of a pattern worth naming: three chart versions in a row were written from
# memory, and each was wrong - one of them (metrics-server 3.13.0) did not exist at all. Each was
# caught only because a human happened to run `helm search repo` first. That is a process that
# depends on remembering, which means it is a process that will fail.
#
# A pin is supposed to be a decision. A decision needs the current value in front of it. So this
# prints both and says nothing about which is better: being behind is often correct, and the
# point is to know rather than to chase.
#
# It never changes anything. Moving a pin stays a deliberate edit plus `make gitops-lock`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_hdr=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

command -v helm >/dev/null || { echo "helm not installed - run: make tools" >&2; exit 1; }
command -v yq   >/dev/null || { echo "yq not installed - run: make tools" >&2; exit 1; }

printf '%s%-18s %-14s %-14s %s%s\n' "$c_hdr" "CHART" "PINNED" "LATEST" "REPOSITORY" "$c_off"

behind=0
found=0

for chart in "$REPO_ROOT"/gitops/charts/*/Chart.yaml; do
  [[ -f "$chart" ]] || continue
  dir=$(dirname "$chart")

  # A wrapper chart may legitimately have no dependencies - one that only carries templates of
  # its own. Nothing to check there.
  deps=$(yq -r '.dependencies // [] | length' "$chart")
  [[ "$deps" == "0" ]] && continue

  for i in $(seq 0 $((deps - 1))); do
    name=$(yq -r ".dependencies[$i].name" "$chart")
    pinned=$(yq -r ".dependencies[$i].version" "$chart")
    url=$(yq -r ".dependencies[$i].repository" "$chart")
    found=$((found + 1))

    # Find a local helm repo alias pointing at this URL. Matching by URL rather than by name
    # because the alias is whatever whoever ran `helm repo add` happened to type.
    alias=$(helm repo list -o json 2>/dev/null \
            | yq -r ".[] | select(.url == \"${url%/}\" or .url == \"${url}\") | .name" | head -1)

    if [[ -z "$alias" ]]; then
      printf '%s%-18s %-14s %-14s %s%s\n' "$c_warn" "$name" "$pinned" "repo not added" "$url" "$c_off"
      printf '%s                   helm repo add <alias> %s%s\n' "$c_dim" "$url" "$c_off"
      continue
    fi

    latest=$(helm search repo "$alias/$name" --versions -o json 2>/dev/null \
             | yq -r '.[0].version // ""')

    if [[ -z "$latest" ]]; then
      printf '%s%-18s %-14s %-14s %s (alias %s)%s\n' "$c_warn" "$name" "$pinned" "not found" "$url" "$alias" "$c_off"
    elif [[ "$latest" == "$pinned" ]]; then
      printf '%s%-18s %-14s %-14s %s%s\n' "$c_ok" "$name" "$pinned" "$latest" "$url" "$c_off"
    else
      printf '%s%-18s %-14s %-14s %s%s\n' "$c_warn" "$name" "$pinned" "$latest" "$url" "$c_off"
      behind=$((behind + 1))
    fi
  done
done

echo
if [[ "$found" == 0 ]]; then
  echo "No wrapper charts with dependencies yet."
elif [[ "$behind" == 0 ]]; then
  printf '%sEvery pin matches the newest published version.%s\n' "$c_ok" "$c_off"
else
  printf '%s%d pin(s) behind.%s\n' "$c_warn" "$behind" "$c_off"
  cat <<'EOT'

  Being behind is often the right answer - a pin exists so that nothing moves without a
  decision. This only tells you the decision is available to make.

  To move one:
    1. edit the version in gitops/charts/<name>/Chart.yaml
    2. make gitops-lock                      regenerate Chart.lock (the digest)
    3. make gitops-render CHART=<name>        read the diff in the rendered output
    4. commit the version and the lock TOGETHER, with the reason
EOT
fi

# ---------------------------------------------------------------- git-sourced charts
#
# A chart rendered from a GIT source is invisible to the loop above: there is no local
# Chart.yaml, so there is no dependency to compare. local-path-provisioner is one of these,
# because Rancher publishes no Helm repository for it (ADR-0015).
#
# Two different questions get asked here, and only the first is the same as above:
#
#   is a newer tag available?   - information, same as a chart version being behind.
#   does the pinned tag still point where it did?  - a MOVED TAG, which is not the same thing
#     at all. Argo CD follows a tag, so a re-tagged upstream release would be synced silently.
#     The Gateway API bundle is pinned by content digest and cannot do this; a git tag can, and
#     the only defence here is noticing.

printf '\n%s%-22s %-10s %-10s %s%s\n' "$c_hdr" "GIT CHART" "PINNED" "NEWEST" "RESOLVES TO" "$c_off"

# Our own repository, so its sources are skipped - derived rather than hardcoded, because this
# repo has been cloned under more than one name already.
ours=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//' || echo '')

git_found=0
moved=0

for app in "$REPO_ROOT"/gitops/clusters/*/platform/*.yaml; do
  [[ -f "$app" ]] || continue
  n=$(yq -r '.spec.sources // [] | length' "$app" 2>/dev/null || echo 0)
  [[ "$n" == "0" || -z "$n" ]] && continue

  for i in $(seq 0 $((n - 1))); do
    url=$(yq -r ".spec.sources[$i].repoURL // \"\"" "$app")
    rev=$(yq -r ".spec.sources[$i].targetRevision // \"\"" "$app")
    cpath=$(yq -r ".spec.sources[$i].path // \"\"" "$app")

    # A chart, from somewhere else, over git. A Helm-repo source has no `path`; our own repo is
    # where the values live, not a chart.
    [[ -z "$cpath" || -z "$rev" ]] && continue
    [[ -n "$ours" && "$url" == "$ours"* ]] && continue
    [[ "$url" != *.git ]] && continue

    git_found=$((git_found + 1))
    name=$(basename "$cpath")

    sha=$(git ls-remote "$url" "refs/tags/$rev" 2>/dev/null | awk '{print $1}' | head -1)
    # Release candidates are not newer than the release they preceded. `sort -V` disagrees:
    # it puts v0.0.37-rc2 after v0.0.37, so the first version of this reported the pinned
    # v0.0.37 as being behind v0.0.37-rc2 - advice to downgrade onto a pre-release, phrased as
    # a version check. Anything with a hyphen in the tag is a pre-release by convention.
    newest=$(git ls-remote --tags --refs "$url" 2>/dev/null \
             | awk -F/ '{print $NF}' | grep -E '^v?[0-9]' | grep -v -- '-' \
             | sort -V | tail -1)

    if [[ -z "$sha" ]]; then
      printf '%s%-22s %-10s %-10s unreachable or tag missing%s\n' \
        "$c_warn" "$name" "$rev" "${newest:-?}" "$c_off"
      continue
    fi

    short="${sha:0:7}"
    colour="$c_ok"
    note=""

    # The recorded commit, for the one git source this project has. Compared by prefix because
    # a release page shows a short SHA and ls-remote returns the full one.
    recorded=""
    if [[ "$url" == "$(jq -r '.storage.local_path_repo // "x"' "$REPO_ROOT/clusters/onprem/nodes.json")" ]]; then
      recorded=$(jq -r '.storage.local_path_commit // ""' "$REPO_ROOT/clusters/onprem/nodes.json")
    fi

    if [[ -n "$recorded" ]]; then
      if [[ "$sha" == "$recorded"* ]]; then
        note="matches nodes.json"
      else
        colour="$c_warn"
        note="MOVED - nodes.json records $recorded"
        moved=$((moved + 1))
      fi
    else
      colour="$c_warn"
      note="no commit recorded in nodes.json - record $short"
    fi

    [[ -n "$newest" && "$newest" != "$rev" ]] && note="$note; newest tag $newest"

    printf '%s%-22s %-10s %-10s %s  %s%s\n' \
      "$colour" "$name" "$rev" "${newest:-?}" "$short" "$note" "$c_off"
  done
done

if [[ "$git_found" == 0 ]]; then
  printf '%s  (none)%s\n' "$c_dim" "$c_off"
elif [[ "$moved" != 0 ]]; then
  cat <<'EOT'

  A PINNED TAG HAS MOVED. Upstream re-pointed a tag this cluster syncs from, so Argo CD is
  rendering different code under the same version number. Read the upstream diff between the
  two commits before doing anything else; if the move is legitimate, record the new commit in
  clusters/onprem/nodes.json in the same commit as whatever else changes because of it.
EOT
fi

# ---------------------------------------------------------------- container images
#
# The chart pins are about CHARTS. This section is about the images those charts run, and it asks
# a second question the chart pins cannot: is each pod running the bytes Git asked for?
#
# That distinction is the lesson of ADR-0012's postscript transplanted to images. A tag in a
# values file is a REQUEST. `imagePullPolicy: IfNotPresent` means a pod keeps whatever it pulled
# when it first started, so a tag can be re-pointed, or edited in Git, and every pod goes on
# running the old bytes while the manifest claims otherwise. The running digest is the answer.
#
# Three columns, and the third is the one worth reading:
#   PINNED    - the tag the overlay asks for
#   REGISTRY  - what that tag resolves to in the registry, right now
#   RUNNING   - what the pod is actually executing
#
# REGISTRY != RUNNING means a restart would change the application. PINNED being a moving tag
# like `latest` means that can happen without any commit at all.

printf '\n%s%-18s %-14s %-11s %-11s %s%s\n' \
  "$c_hdr" "IMAGE" "PINNED" "REGISTRY" "RUNNING" "" "$c_off"

img_ns=$(yq -r '.spec.destination.namespace // ""' \
         "$REPO_ROOT/gitops/clusters/onprem/apps/shopverse.yaml" 2>/dev/null || echo '')
img_want=$(yq -r '.global.imageTag // ""' \
           "$REPO_ROOT/gitops/environments/onprem/shopverse.yaml" 2>/dev/null || echo '')

img_found=0; img_drift=0; img_unknown=0; img_moving=0

if [[ -z "$img_ns" || -z "$img_want" ]]; then
  printf '%s  (no tenant overlay to check)%s\n' "$c_dim" "$c_off"
elif ! kubectl get namespace "$img_ns" >/dev/null 2>&1; then
  printf '%s  (%s not present - nothing running to compare against)%s\n' "$c_dim" "$img_ns" "$c_off"
else
  while read -r image running; do
    [[ -z "${image:-}" ]] && continue
    repo="${image%:*}"
    # The running value is "repo@sha256:...". Everything before the @ is the repo as the KUBELET
    # resolved it, which is not always how the manifest spelled it.
    run_digest="${running#*@}"

    if [[ "$repo" != ghcr.io/* ]]; then
      # mongo:7.0 and anything else from another registry. Not unpinned - `7.0` is a real
      # version - and looking it up needs a different auth dance, so it is reported and skipped.
      printf '%s%-18s %-14s %-11s %-11s external registry, skipped%s\n' \
        "$c_dim" "${repo##*/}" "${image##*:}" "-" "${run_digest:7:9}" "$c_off"
      continue
    fi

    path="${repo#ghcr.io/}"
    svc="${path##*/}"
    img_found=$((img_found + 1))

    tk=$(curl -sS --max-time 15 \
         "https://ghcr.io/token?scope=repository:${path}:pull&service=ghcr.io" 2>/dev/null \
         | jq -r '.token // empty' 2>/dev/null || true)
    reg_digest=""
    if [[ -n "$tk" ]]; then
      reg_digest=$(curl -sS --max-time 15 -H "Authorization: Bearer $tk" \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
        -o /dev/null -w '%header{docker-content-digest}' \
        "https://ghcr.io/v2/${path}/manifests/${img_want}" 2>/dev/null || true)
    fi

    # AN EMPTY DIGEST IS NEVER A MATCH. This guard exists because a lookup written without it
    # reported eight tags as identical to `latest` when in fact every single request had failed
    # and it was comparing "" to "" - a check that agreed with whoever ran it, eight times.
    if [[ -z "$reg_digest" ]]; then
      printf '%s%-18s %-14s %-11s %-11s LOOKUP FAILED - no comparison made%s\n' \
        "$c_warn" "$svc" "$img_want" "?" "${run_digest:7:9}" "$c_off"
      img_unknown=$((img_unknown + 1))
      continue
    fi

    note=""; colour="$c_ok"
    if [[ "$reg_digest" != "$run_digest" ]]; then
      colour="$c_warn"; note="DRIFT - a restart would change this pod"
      img_drift=$((img_drift + 1))
    fi
    case "$img_want" in
      latest|main|master|stable|edge)
        colour="$c_warn"
        note="${note:+$note; }moving tag - can change with no commit"
        img_moving=$((img_moving + 1)) ;;
    esac

    printf '%s%-18s %-14s %-11s %-11s %s%s\n' \
      "$colour" "$svc" "$img_want" "${reg_digest:7:9}" "${run_digest:7:9}" "$note" "$c_off"
  done < <(kubectl -n "$img_ns" get pods \
            -o jsonpath='{range .items[*]}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].imageID}{"\n"}{end}' \
            2>/dev/null | sort -u)

  if [[ "$img_unknown" != 0 ]]; then
    printf '\n  %s lookup(s) failed. That is not "no drift" - it is no answer. Check network\n' "$img_unknown"
    printf '  access to ghcr.io before reading anything above as reassurance.\n'
  fi
  if [[ "$img_moving" != 0 ]]; then
    cat <<'EOT'

  A MOVING TAG. Everything else here is pinned by version, digest or commit; an image tag like
  `latest` means the cluster can change what it runs with no commit anywhere. The REGISTRY column
  above is what a new pod would get today. To pin it, find the immutable tag with that digest:

    s=frontend   # or any service above
    tk=$(curl -s "https://ghcr.io/token?scope=repository:shaggydesai/microservice-app/$s:pull&service=ghcr.io" | jq -r .token)
    curl -s -H "Authorization: Bearer $tk" https://ghcr.io/v2/shaggydesai/microservice-app/$s/tags/list | jq -r '.tags[]'

  then compare digests tag by tag and set global.imageTag in
  gitops/environments/onprem/shopverse.yaml to the sha-* one that matches.
EOT
  fi
  if [[ "$img_drift" != 0 ]]; then
    cat <<'EOT'

  DRIFT between the registry and a running pod. The pod is executing bytes the manifest no longer
  resolves to, which is invisible until something restarts it and then surprising. Either the tag
  moved under you, or the pin changed in Git and nothing has restarted since.

    kubectl -n <ns> rollout restart deployment --all

EOT
  fi
fi

# Deliberately exit 0 even when pins are behind. This is information, not a failure: `make lint`
# should not break because an upstream project published a release this morning.
exit 0
