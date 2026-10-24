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

[[ -d "$chart_dir" ]] || die "no such chart: $chart_dir
available: $(ls -1 gitops/charts 2>/dev/null | tr '\n' ' ')"
[[ -f "$app" ]] || die "no Application for $CHART in $ENV: $app
A chart with no Application is a chart nothing deploys - which is worth knowing."

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
