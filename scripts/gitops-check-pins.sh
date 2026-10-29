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
    newest=$(git ls-remote --tags --refs "$url" 2>/dev/null \
             | awk -F/ '{print $NF}' | grep -E '^v?[0-9]' | sort -V | tail -1)

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

# Deliberately exit 0 even when pins are behind. This is information, not a failure: `make lint`
# should not break because an upstream project published a release this morning.
exit 0
