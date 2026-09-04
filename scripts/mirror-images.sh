#!/usr/bin/env bash
# Mirror every image in infra/helm/images.txt into the in-universe Artifact Registry.
#
# GCD has no remote or virtual Artifact Registry repos, so there is no pull-through
# mirror. Every image has to be pushed by hand before any Helm install will work.
#
# Usage: scripts/mirror-images.sh [--dry-run]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -f .env.local ]]; then
  echo "error: .env.local not found. Copy .env.local.example and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env.local

: "${AR_PREFIX:?set AR_PREFIX in .env.local}"
if [[ "${AR_PREFIX}" == /* || "${AR_PREFIX}" == //* ]]; then
  echo "error: AR_HOST is empty. Berlin's registry hostname is still unconfirmed." >&2
  exit 1
fi

MANIFEST="infra/helm/images.txt"
[[ -f "${MANIFEST}" ]] || { echo "error: ${MANIFEST} not found" >&2; exit 1; }

if command -v crane >/dev/null 2>&1; then
  COPY=crane
elif command -v docker >/dev/null 2>&1; then
  COPY=docker
else
  echo "error: need crane (preferred, multi-arch safe) or docker" >&2
  exit 1
fi
echo "using: ${COPY}"

# ── two registries, two identities ───────────────────────────────────────────
# This mirror pulls from a PUBLIC-GCP registry (us-docker.pkg.dev/solo-public)
# and pushes to the UNIVERSE registry (pkg-berlin-build0.goog). Those need
# different credentials, and docker cannot hold both through the gcloud
# credential helper: ~/.docker/config.json maps us-docker.pkg.dev to the
# `gcloud` helper, which resolves against whichever gcloud configuration is
# ACTIVE. During a GCD session that is `berlin`, whose token has no standing at
# us-docker.pkg.dev, so every source pull fails with a confusing
# "invalid_grant: Refresh token has expired" that looks like the Berlin login
# is broken when it is the public one being consulted.
#
# Fix: run under an isolated DOCKER_CONFIG that carries an inline token for the
# public source registry and delegates only the universe host to the gcloud
# helper. Tom's real ~/.docker/config.json is left untouched.
setup_dual_registry_auth() {
  local pub_account="${SOLO_GCP_ACCOUNT:-tom.orourke@solo.io}"
  local pub_registry="us-docker.pkg.dev"
  local dst_registry="${AR_PREFIX%%/*}"

  local token
  token="$(gcloud auth print-access-token --account="$pub_account" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    local legacy="$HOME/.config/gcloud/legacy_credentials/${pub_account}/adc.json"
    [[ -f "$legacy" ]] && token="$(python3 - "$legacy" <<'PYTOK'
import json, sys, urllib.parse, urllib.request
d = json.load(open(sys.argv[1]))
data = urllib.parse.urlencode({
    "client_id": d["client_id"], "client_secret": d["client_secret"],
    "refresh_token": d["refresh_token"], "grant_type": "refresh_token",
}).encode()
try:
    r = urllib.request.urlopen(
        urllib.request.Request("https://oauth2.googleapis.com/token", data=data), timeout=20)
    print(json.load(r)["access_token"])
except Exception:
    pass
PYTOK
)"
  fi

  if [[ -z "$token" ]]; then
    echo "warn: no public-GCP token for ${pub_account}; source pulls from" >&2
    echo "      ${pub_registry} will fail. Images already present locally will" >&2
    echo "      still be pushed." >&2
    return 0
  fi

  DOCKER_CONFIG="$(mktemp -d)"
  export DOCKER_CONFIG
  python3 - "$DOCKER_CONFIG" "$token" "$pub_registry" "$dst_registry" <<'PYCFG'
import base64, json, os, sys
cfgdir, tok, pub, dst = sys.argv[1:5]
auth = base64.b64encode(f"oauth2accesstoken:{tok}".encode()).decode()
cfg = {
    "auths": {pub: {"auth": auth}},
    # Only the universe host goes through the gcloud helper, which resolves
    # against the active (berlin) configuration -- which is what we want for
    # the push.
    "credHelpers": {dst: "gcloud"},
}
json.dump(cfg, open(os.path.join(cfgdir, "config.json"), "w"))
PYCFG
  echo "using isolated DOCKER_CONFIG: pull=${pub_registry} (public GCP), push=${dst_registry} (universe)"
}
setup_dual_registry_auth

while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "${line}" | xargs || true)"
  [[ -z "${line}" ]] && continue

  # Destination keeps the repository path and tag, drops the source registry host.
  path="${line#*/}"
  dst="${AR_PREFIX}/${path}"

  echo "  ${line}"
  echo "    -> ${dst}"
  if (( DRY_RUN )); then
    continue
  fi

  case "${COPY}" in
    crane)
      crane copy "${line}" "${dst}"
      ;;
    docker)
      # Single-arch only. Prefer crane for anything shipping multi-arch manifests.
      docker pull "${line}"
      docker tag "${line}" "${dst}"
      docker push "${dst}"
      ;;
  esac
done < "${MANIFEST}"

echo "done."
