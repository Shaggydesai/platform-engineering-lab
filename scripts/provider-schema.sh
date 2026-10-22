#!/usr/bin/env bash
# Print a provider's real resource schema, from the plugin that is actually installed.
#
# Provider documentation on the web is frequently for a different version than the one
# Terraform resolved. This asks Terraform instead, which cannot be wrong.
#
#   ./scripts/provider-schema.sh terraform/onprem libvirt_domain libvirt_volume
#   ./scripts/provider-schema.sh terraform/onprem            # every resource, depth 2
set -euo pipefail

DIR="${1:?usage: provider-schema.sh <terraform-dir> [resource ...]}"
shift || true
DEPTH="${DEPTH:-3}"
FILTER='.'
if [[ $# -gt 0 ]]; then
  pattern="$(printf '%s|' "$@" | sed 's/|$//')"
  FILTER="select(.key | test(\"^($pattern)$\"))"
fi

terraform -chdir="$DIR" providers schema -json > /tmp/tf-schema.json

jq -r --argjson maxd "$DEPTH" '
  def emit($p; $d):
    if $d > $maxd then "\($p)..." else
      ( (.attributes // {}) | to_entries[]
        | "\($p)\(.key)\(if .value.required then " *" else "" end)\(if .value.nested_type then " {\(.value.nested_type.nesting_mode)}" else "" end)",
          ( if .value.nested_type then (.value.nested_type | emit("\($p)  "; $d+1)) else empty end ) ),
      ( (.block_types // {}) | to_entries[]
        | "\($p)\(.key) [block \(.value.nesting_mode)]",
          (.value.block | emit("\($p)  "; $d+1)) )
    end;
  .provider_schemas | to_entries[] | .key as $prov
  | .value.resource_schemas | to_entries[] | '"$FILTER"'
  | "=== \(.key)   (\($prov))", (.value.block | emit("  "; 1)), ""
' /tmp/tf-schema.json
