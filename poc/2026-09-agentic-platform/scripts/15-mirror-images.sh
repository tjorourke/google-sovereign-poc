#!/usr/bin/env bash
# 15-mirror-images.sh — mirror every image the platform needs into the
# in-universe Artifact Registry.
#
# GCD's Artifact Registry is standard-mode only: NO remote and NO virtual
# repositories, therefore no pull-through mirror. Every image has to be pushed
# explicitly. This wraps the repo-level scripts/mirror-images.sh with the AR
# host resolved from the API rather than composed, and it verifies the eu0:
# colon question (probe 0.8) before pushing anything.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud docker
load_env
assert_universe

: "${AR_REPO:?}" "${AR_LOCATION:?}"

# ── resolve the real registry host. Never compose it. ────────────────────────
step "resolving the Artifact Registry host from the API"
URI="$(gcloud artifacts repositories describe "$AR_REPO" \
  --project "$PROJECT_ID" --location "$AR_LOCATION" \
  --format='value(registryUri)' 2>/dev/null || true)"
[[ -n "$URI" ]] || die "repo '$AR_REPO' not found in $AR_LOCATION — run 10-tofu.sh apply first"
ok "registryUri = $URI"

REAL_HOST="${URI%%/*}"
if [[ -n "${AR_HOST:-}" && "$REAL_HOST" != "$AR_HOST" ]]; then
  warn "AR_HOST in .env.local is '$AR_HOST' but the API says '$REAL_HOST'"
  warn "update .env.local — the <region>-docker prefix is a public-GCP convention"
fi

# ── probe 0.8: does the eu0: colon survive a docker reference? ───────────────
# A colon is legal in a docker reference only in the host (as a port) or as the
# tag separator. It is NOT legal inside a path component. If registryUri carries
# the eu0: prefix in the path, standard docker/containerd/helm clients may
# refuse the ref outright — which would be a first-class ISV finding.
step "0.8 checking the eu0: colon against the docker reference grammar"
PATH_PART="${URI#*/}"
if [[ "$PATH_PART" == *:* ]]; then
  warn "registryUri path component contains a colon: '$PATH_PART'"
  warn "expect docker/containerd/crane/helm to reject refs built from this."
  warn "RECORD THIS as a finding, then retry with the unprefixed project id."
  evidence "ar-colon-probe-0.8" gcloud artifacts repositories describe "$AR_REPO" \
    --project "$PROJECT_ID" --location "$AR_LOCATION" --format=json >/dev/null || true
else
  ok "no colon in the path component — standard docker refs are safe"
fi

AR_PREFIX_RESOLVED="${URI}"
log "images will be pushed under: ${AR_PREFIX_RESOLVED}/<repo-path>:<tag>"

# ── docker auth against the in-universe registry ────────────────────────────
step "authenticating docker to $REAL_HOST"
ar_docker_login "$REAL_HOST"

# Push a one-byte probe image before doing anything expensive, so a broken
# reference or a missing permission fails in five seconds not fifteen minutes.
step "push probe (fails fast if the ref or the permission is wrong)"
PROBE_TAG="${AR_PREFIX_RESOLVED}/gcd-probe:1"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf 'FROM scratch\nCOPY Dockerfile /probe\n' >"$TMPD/Dockerfile"
if docker build -q -t "$PROBE_TAG" "$TMPD" >/dev/null 2>&1 && docker push "$PROBE_TAG" >/dev/null 2>&1; then
  ok "push probe succeeded — the registry accepts our references"
  docker rmi "$PROBE_TAG" >/dev/null 2>&1 || true
else
  die "push probe FAILED against $PROBE_TAG — record verbatim, this is probe 0.8/0.4 answering no"
fi

# ── mirror ───────────────────────────────────────────────────────────────────
step "mirroring infra/helm/images.txt"
AR_PREFIX="$AR_PREFIX_RESOLVED" "$REPO_ROOT/scripts/mirror-images.sh" "$@"

cat >&2 <<EOF

  Mirrored. Every values file must now template the registry at:
    ${AR_PREFIX_RESOLVED}

  Never hardcode ghcr.io, pkg.dev or us-docker.pkg.dev into anything that runs
  in-universe — that is the repo rule and it is the thing that has to survive
  the staging domains being renamed at GA.
EOF
