#!/usr/bin/env bash
# Module 06's gate, as a command that can fail.
#
#   make shopverse-check
#
# The roadmap's bar is behavioural: "open the storefront over HTTPS with a trusted certificate,
# add an item to the cart and complete a checkout, and the order survives a Pod restart."
#
# The browser half of that is a human act and stays one. Everything else is a sequence of HTTP
# requests and a pod deletion, so it belongs in a script - a manual checkout proves it worked
# once, for whoever happened to be watching.
#
# It is DESTRUCTIVE in two ways that are stated up front rather than discovered: it creates a real
# user and a real order in the tenant's database, and it DELETES THE MONGODB POD. The second one
# is the entire point.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG=clusters/onprem/nodes.json
CA=.cache/platform-ca.crt
NS=$(yq -r '.spec.destination.namespace' gitops/clusters/onprem/apps/shopverse.yaml 2>/dev/null || echo shopverse-prod)
HOST=$(jq -r '.loadbalancer.gateway_hostnames[]? | select(test("shopverse"))' "$CONFIG" | head -1)
MONGO_POD=shopverse-mongodb-0

c_step=$'\033[36m'; c_ok=$'\033[32m'; c_err=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s%s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s%s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq not installed - run: make tools"
[[ -n "$HOST" ]] || die "no shopverse hostname in $CONFIG (.loadbalancer.gateway_hostnames)"
[[ -f "$CA" ]]   || die "$CA missing - run: make onprem-ca"

BASE="https://$HOST"
# --cacert, never -k. The point of ADR-0011's PKI is that the certificate VERIFIES; skipping
# verification here would quietly turn a broken certificate into a passing test.
CURL=(curl -sS --max-time 20 --cacert "$CA")

# Sets two GLOBALS, REQ_BODY and REQ_CODE, and prints nothing.
#
# It does NOT return the body on stdout, and that is the whole point. The first version did, so
# every call site read `body=$(req GET /)` - a command substitution, which runs the function
# in a SUBSHELL, so the REQ_CODE it set was discarded on the way out. Every `expect` then
# compared an empty string against 200 and died on step one, blaming the storefront.
#
# Found by running it against a stub API, not by reading it. The bodies all parsed correctly;
# only the status codes were silently empty, which is exactly the shape of bug that reads as
# "the platform is broken".
req() {  # req METHOD PATH [JSON_BODY]
  local method=$1 path=$2 payload=${3:-}
  local args=("${CURL[@]}" -X "$method" -w '\n%{http_code}' "$BASE$path")
  [[ -n "$payload" ]] && args+=(-H 'Content-Type: application/json' -d "$payload")
  [[ -n "${TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $TOKEN")
  local out; out=$("${args[@]}" 2>&1)
  REQ_CODE=$(printf '%s' "$out" | tail -1)
  REQ_BODY=$(printf '%s' "$out" | sed '$d')
}

expect() {  # expect WHAT EXPECTED_CODE   (reads the globals req() set)
  local what=$1 want=$2
  if [[ "$REQ_CODE" == "$want" ]]; then
    ok "$what -> $REQ_CODE"
  else
    printf '    %s%s -> %s (wanted %s)%s\n' "$c_err" "$what" "${REQ_CODE:-<empty>}" "$want" "$c_off"
    printf '%s%s%s\n' "$c_dim" "$(printf '%s' "${REQ_BODY:-}" | head -c 500)" "$c_off"
    die "FAILED at: $what"
  fi
}

printf '%sShopVerse end-to-end check against %s%s\n\n' "$c_step" "$BASE" "$c_off"
printf 'This creates a real user and a real order in %s, and then DELETES %s\n' "$NS" "$MONGO_POD"
printf 'to prove the order survives it. That is the Module 06 gate, not a side effect.\n\n'
read -r -p "continue? [y/N] " a; [[ "$a" == y || "$a" == Y ]] || exit 1
echo

# ---------------------------------------------------------------- 1
step '1/7 the storefront answers over HTTPS, with a certificate that verifies'
req GET /
expect "GET /" 200
ok 'the CA verifies - no -k anywhere in this script'

# ---------------------------------------------------------------- 2
step '2/7 the catalogue (nginx -> api-gateway -> product-service -> MongoDB)'
req GET /api/products
expect "GET /api/products" 200
count=$(printf '%s' "$REQ_BODY" | jq -r '.items | length' 2>/dev/null || echo 0)
[[ "$count" -gt 0 ]] || die "the catalogue is empty - SEED_DATA should have populated it"
# _id or id: the handler returns Mongo documents and which one surfaces depends on a transform
# this script has not read. Accepting either is honest; guessing one is how a check fails for a
# reason that has nothing to do with the platform.
PRODUCT_ID=$(printf '%s' "$REQ_BODY" | jq -r '.items[0]._id // .items[0].id // empty')
PRODUCT_NAME=$(printf '%s' "$REQ_BODY" | jq -r '.items[0].name // "?"')
[[ -n "$PRODUCT_ID" ]] || die "could not read a product id from the first item"
ok "$count products; using \"$PRODUCT_NAME\" ($PRODUCT_ID)"

# ---------------------------------------------------------------- 3
step '3/7 register a shopper'
EMAIL="check-$(date +%s)-$RANDOM@shopverse.local"
req POST /api/users/register \
  "{\"name\":\"Check Runner\",\"email\":\"$EMAIL\",\"password\":\"check-password-123\"}"
expect "POST /api/users/register" 201
TOKEN=$(printf '%s' "$REQ_BODY" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || die "register returned no token"
# A fresh email every run, so a second run does not fail with 409 Email already registered -
# which would look like a broken user-service.
ok "registered $EMAIL and got a token"

# ---------------------------------------------------------------- 4
step '4/7 add it to the cart'
req POST /api/cart/items "{\"productId\":\"$PRODUCT_ID\",\"quantity\":1}"
expect "POST /api/cart/items" 201
ok "cart has $(printf '%s' "$REQ_BODY" | jq -r '.items | length') line(s)"

# ---------------------------------------------------------------- 5
step '5/7 check out'
req POST /api/orders '{
  "paymentMethod": "COD",
  "shippingAddress": {
    "fullName": "Check Runner", "phone": "9999999999",
    "line1": "1 Platform Lane", "city": "Pune", "state": "MH", "pincode": "411001"
  }
}'
expect "POST /api/orders" 201
ORDER=$(printf '%s' "$REQ_BODY" | jq -r '.orderNumber // empty')
[[ -n "$ORDER" ]] || die "checkout returned no orderNumber"
TOTAL=$(printf '%s' "$REQ_BODY" | jq -r '.amounts.total // "?"')
ok "order $ORDER placed, total $TOTAL"
# That one request crossed order-service -> cart-service, -> product-service twice (reserve and
# price) and -> payment-service. Five of the seven services, in one call.

# ---------------------------------------------------------------- 6
step "6/7 delete $MONGO_POD and wait for it to come back"
pvc_before=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].spec.volumeName}' 2>/dev/null || true)
node_before=$(kubectl -n "$NS" get pod "$MONGO_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
warn "this is the destructive step"
kubectl -n "$NS" delete pod "$MONGO_POD" --wait=true >/dev/null || die "could not delete $MONGO_POD"
kubectl -n "$NS" wait --for=condition=Ready "pod/$MONGO_POD" --timeout=180s >/dev/null \
  || die "$MONGO_POD did not become Ready again within 180s"
node_after=$(kubectl -n "$NS" get pod "$MONGO_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
pvc_after=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].spec.volumeName}' 2>/dev/null || true)
ok "back as Ready on $node_after (was $node_before)"
if [[ "$pvc_before" == "$pvc_after" ]]; then
  ok "same PersistentVolume: $pvc_after"
else
  die "the PersistentVolume changed ($pvc_before -> $pvc_after) - that is not persistence"
fi
# The node is expected to be the SAME one. platform-local volumes are node-local (ADR-0015), so
# the PV's node affinity pins the pod. If this ever reports a different node, either the storage
# class changed or something is very wrong - and the order check below would fail anyway.

# ---------------------------------------------------------------- 7
step '7/7 the order is still there'
# Retried: Mongo accepts connections before the services have reconnected, so the first request
# after a restart can legitimately fail. A single attempt here would make this check flaky and
# teach everyone to re-run it, which is how a real failure gets ignored.
for i in $(seq 1 15); do
  req GET "/api/orders/$ORDER"
  [[ "$REQ_CODE" == 200 ]] && break
  printf '    %sattempt %s: %s, retrying%s\n' "$c_dim" "$i" "$REQ_CODE" "$c_off"
  sleep 3
done
expect "GET /api/orders/$ORDER" 200
got=$(printf '%s' "$REQ_BODY" | jq -r '.orderNumber // empty')
[[ "$got" == "$ORDER" ]] || die "read back $got, expected $ORDER"
ok "order $ORDER survived the restart, total $(printf '%s' "$REQ_BODY" | jq -r '.amounts.total // "?"')"

echo
printf '%sShopVerse end-to-end check passed%s\n' "$c_ok" "$c_off"
echo
printf 'What this did NOT test: a browser. The roadmap asks for the storefront opened over\n'
printf 'HTTPS with a TRUSTED certificate, which means the CA imported into an OS trust store -\n'
printf 'a change to a machine, not to this repository. See docs/runbooks/06-shopverse.md.\n'
printf '\nThe user and order created above are left in place. They are a tenant going about its\n'
printf 'business, and deleting them would make this script own data it did not need to own.\n'
