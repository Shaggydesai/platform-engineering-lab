#!/usr/bin/env bash
# Resolve a container image reference to its immutable digest.
#
#   scripts/image-digest.sh docker.io/library/busybox latest
#   scripts/image-digest.sh ghcr.io/argoproj/argocd v3.5.5
#
# WHY THIS EXISTS. This project pins by CONTENT wherever it can - the Gateway API bundle carries a
# sha256 the Ansible role verifies before applying, because a version tag is a mutable pointer and
# a digest is not. Images were the gap: `make lint` has nothing to check them against, and
# "unpinned, and nobody here has read the value" sat in the parking lot from 2026-10-29 because
# resolving a digest needed a tool nobody had and a registry call nobody had made.
#
# It is a registry API call and a header, not a tool: an anonymous pull token, then a HEAD on the
# manifest, and the registry returns `Docker-Content-Digest`. No docker, no crane, no skopeo, and
# nothing is downloaded - a HEAD on a manifest transfers no layers.
#
# A DIGEST IS NOT A VERSION, which is the thing to keep straight. Pinning
# `busybox@sha256:<hex>` says "these exact bytes, the ones that were inspected", and it keeps
# saying that forever. `busybox:1.37.0` says "whatever the publisher currently calls 1.37.0",
# which is usually stable and is not guaranteed to be. `busybox:latest` says nothing at all.
#
# Three outcomes, per ADR-0003:
#   0  the digest, on stdout, alone, so it can be captured by a shell
#   1  the registry answered and this image or tag does not exist
#   2  the registry could not be reached, which is NOT the same as "not there"
set -uo pipefail

c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
note() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off" >&2; }

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <repository> <tag>
  e.g. $(basename "$0") docker.io/library/busybox latest
       $(basename "$0") ghcr.io/argoproj/argocd v3.5.5

  The repository must be FULLY QUALIFIED. 'busybox' is not a repository - the Docker CLI
  expands it to docker.io/library/busybox, and nothing else does, so a short name here
  would work by accident on one registry and fail on every other."

REPO="$1"
TAG="$2"
command -v curl >/dev/null || die "curl is not on PATH"

# Split the registry host off the repository path. A host is the first segment only when it looks
# like one - it contains a dot or a colon, or it is literally localhost. Without that rule,
# `library/busybox` would read `library` as a hostname.
host="${REPO%%/*}"
if [[ "$host" == "$REPO" || ( "$host" != *.* && "$host" != *:* && "$host" != localhost ) ]]; then
  die "$REPO has no registry host - write docker.io/library/${REPO} if you meant Docker Hub"
fi
path="${REPO#*/}"

# docker.io is an alias: the registry that actually serves it is registry-1.docker.io, and its
# auth lives on a third host again. Everything else serves its own token endpoint.
case "$host" in
  docker.io|index.docker.io) api="registry-1.docker.io" ;;
  *)                         api="$host" ;;
esac

# THE TOKEN IS ANONYMOUS AND PUBLIC. This asks for pull scope on one repository and nothing else,
# so it carries no credential of this user's and grants nothing beyond reading a public manifest.
# A private repository needs a real credential and is out of scope here - it fails with 401, which
# is reported as "could not look" rather than "does not exist".
token_url="https://${api}/v2/"
realm="" service=""
challenge=$(curl -sS -I --max-time 20 "$token_url" 2>/dev/null \
            | tr -d '\r' | grep -i '^www-authenticate:' || true)
if [[ -z "$challenge" ]]; then
  note "no auth challenge from ${api} - trying unauthenticated, which some registries allow"
else
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p'   <<<"$challenge")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
fi

auth_header=()
if [[ -n "$realm" ]]; then
  tok_json=$(curl -sS --max-time 20 \
    "${realm}?service=${service}&scope=repository:${path}:pull" 2>/dev/null) || tok_json=""
  if [[ -z "$tok_json" ]]; then
    note "could not reach the token endpoint at ${realm}"
    exit 2
  fi
  tok=$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
print(d.get("token") or d.get("access_token") or "")' <<<"$tok_json" 2>/dev/null)
  if [[ -z "$tok" ]]; then
    note "the token endpoint answered without a token - a private repository needs a credential"
    exit 2
  fi
  auth_header=(-H "Authorization: Bearer ${tok}")
fi

# ACCEPT ALL FOUR MEDIA TYPES, and this is the part that is easy to get wrong. Ask only for the
# v2 manifest and a multi-architecture image answers 404 or hands back a different digest than
# the one a cluster would pull - because the thing a tag points at for a multi-arch image is an
# INDEX, and the index's digest is the one to pin. A node then resolves its own architecture
# from inside that index, which is exactly what you want: one digest, every architecture.
ACCEPT=(
  -H 'Accept: application/vnd.oci.image.index.v1+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
  -H 'Accept: application/vnd.oci.image.manifest.v1+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
)

# HEAD, not GET: the digest is a response header, so nothing is transferred.
resp=$(curl -sS -I --max-time 30 "${auth_header[@]}" "${ACCEPT[@]}" \
         "https://${api}/v2/${path}/manifests/${TAG}" 2>/dev/null) || {
  note "could not reach https://${api}/v2/${path}/manifests/${TAG}"
  exit 2
}

status=$(head -1 <<<"$resp" | tr -d '\r' | awk '{print $2}')
digest=$(tr -d '\r' <<<"$resp" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | tail -1)

case "$status" in
  200)
    if [[ -z "$digest" ]]; then
      note "${api} returned 200 without a Docker-Content-Digest header"
      exit 2
    fi
    printf '%s\n' "$digest"
    note "${REPO}:${TAG} -> ${digest}"
    note "a tag is a pointer and this is the thing it points at today; pin the digest"
    exit 0
    ;;
  404)
    printf '%sno such image or tag: %s:%s%s\n' "$c_err" "$REPO" "$TAG" "$c_off" >&2
    printf 'The registry answered, so this is a definite no rather than a lookup failure.\n' >&2
    exit 1
    ;;
  401|403)
    note "${api} refused the request (${status}) - a private repository needs a credential"
    exit 2
    ;;
  "")
    note "no HTTP status line from ${api}"
    exit 2
    ;;
  *)
    note "${api} answered ${status}, which this script does not interpret"
    exit 2
    ;;
esac
