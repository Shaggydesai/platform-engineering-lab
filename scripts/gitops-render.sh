#!/usr/bin/env bash
# Render a wrapper chart exactly as Argo CD will, and print nothing Argo CD would not apply.
#
#   make gitops-render CHART=cert-manager [ENV=onprem]
#
# "Exactly as Argo CD will" is the whole value of this, and the first version failed at it: it
# passed --namespace kube-system to every chart, because metrics-server was the only chart when
# it was written. cert-manager's Certificate therefore rendered into kube-system while the real
# one was created in cert-manager - a preview that shows the wrong namespace is worse than no
# preview, because it is believed.
#
# So the namespace comes from the same place Argo CD gets it: the Application's
# spec.destination.namespace. One source of truth, checked rather than assumed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CHART="${1:?usage: gitops-render.sh <chart> [env]}"
ENV="${2:-onprem}"

chart_dir="gitops/charts/$CHART"
env_values="gitops/environments/$ENV/$CHART.yaml"
app="gitops/clusters/$ENV/platform/$CHART.yaml"

c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
die() { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

[[ -f "$app" ]] || die "no Application for $CHART in $ENV: $app
A chart with no Application is a chart nothing deploys - which is worth knowing."

# A chart may not be in this repository at all. local-path-provisioner is rendered from a GIT
# source, because Rancher publishes no Helm repository for it (ADR-0015) - so the first version
# of this script said "no such chart: gitops/charts/local-path" and offered the three local ones,
# which is true and useless. A preview tool that cannot preview the one chart nobody here wrote
# is the wrong way round.
#
# So: if there is no local chart directory, look for a git source in the Application and fetch
# the chart at the PINNED revision. Fetched into .cache, which is gitignored - the point is to
# see what Argo CD will render, not to vendor a copy that then drifts.
if [[ ! -d "$chart_dir" ]]; then
  # No regex. The first version of this used a negative lookahead - `^(?!.*Shaggydesai)` - which
  # jq supports and mikefarah's yq does not: it compiles patterns with Go's regexp engine, where
  # lookahead is not implemented. The filter would have matched nothing, and "no external git
  # source" is indistinguishable from "the filter is broken".
  #
  # So yq only flattens the sources, and the choice of which one is a chart happens in bash
  # against this repository's actual origin URL.
  ours=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//')
  git_url=""; git_rev=""; git_path=""
  while IFS='|' read -r u r pth; do
    [[ -z "${u:-}" || "$u" == "null" ]] && continue
    [[ -n "$ours" && "$u" == "$ours"* ]] && continue
    git_url="$u"; git_rev="$r"; git_path="$pth"
    break
  done < <(yq -r '.spec.sources[]? | select(.path != null)
                  | .repoURL + "|" + .targetRevision + "|" + .path' "$app" 2>/dev/null)

  if [[ -z "$git_url" || "$git_url" == "null" ]]; then
    die "no such chart: $chart_dir
and $app declares no external git source either.
available locally: $(ls -1 gitops/charts 2>/dev/null | tr '\n' ' ')"
  fi

  cache="$REPO_ROOT/.cache/gitchart-$CHART"
  mkdir -p "$(dirname "$cache")"

  # Fetch the one revision rather than cloning history, and re-fetch every time: a stale cache
  # would make this show the chart as it was when someone last ran it, which is the same class
  # of lie the namespace bug above was.
  printf '%s# fetching %s at %s%s\n' "$c_dim" "$git_url" "$git_rev" "$c_off" >&2
  rm -rf "$cache"
  git init -q "$cache"
  git -C "$cache" remote add origin "$git_url"
  if ! git -C "$cache" fetch -q --depth 1 origin "$git_rev" 2>/dev/null; then
    die "could not fetch $git_rev from $git_url
If this is a network problem, nothing is wrong with the repository. If the revision is
genuinely gone, Argo CD cannot sync this Application either - check with:
  make gitops-check-pins"
  fi
  git -C "$cache" checkout -q FETCH_HEAD

  actual=$(git -C "$cache" rev-parse FETCH_HEAD)
  printf '%s# %s resolves to %s%s\n' "$c_dim" "$git_rev" "$actual" "$c_off" >&2

  chart_dir="$cache/$git_path"
  [[ -d "$chart_dir" ]] || die "$git_path does not exist in $git_url at $git_rev"
fi

ns=$(yq -r '.spec.destination.namespace' "$app")
[[ -n "$ns" && "$ns" != "null" ]] || die "$app has no spec.destination.namespace"

# Mirror the Application's valueFiles order: the chart's own values first, then the
# environment's. Helm applies them left to right, with later files winning - and LISTS are
# replaced rather than merged, which is the layering sharp edge documented in
# gitops/charts/metrics-server/values.yaml.
args=(helm template "$CHART" "$chart_dir" --namespace "$ns" -f "$chart_dir/values.yaml")
if [[ -f "$env_values" ]]; then
  args+=(-f "$env_values")
else
  printf '%s# no %s - rendering with the chart defaults only%s\n' "$c_dim" "$env_values" "$c_off" >&2
fi

printf '%s# chart:     %s%s\n'  "$c_dim" "$chart_dir" "$c_off" >&2
printf '%s# values:    %s, %s%s\n' "$c_dim" "$chart_dir/values.yaml" "${env_values:-none}" "$c_off" >&2
printf '%s# namespace: %s  (from %s)%s\n\n' "$c_dim" "$ns" "$app" "$c_off" >&2

exec "${args[@]}"
