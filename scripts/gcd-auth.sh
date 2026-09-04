#!/usr/bin/env bash
# Authenticate against the Berlin GCD universe.
#
# Two things go wrong here and both look like something else:
#   1. Missing universe_domain -> gcloud silently talks to public GCP and you get 403/404
#      on projects that don't exist.
#   2. A "Login successful" browser page means you authenticated against GCP, not GCD.
#      A 404 in the browser is the CORRECT outcome.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env.local ]]; then
  echo "error: .env.local not found. Copy .env.local.example and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env.local

: "${UNIVERSE_NAME:?}" "${UNIVERSE_API_DOMAIN:?}" "${UNIVERSE_WEB_DOMAIN:?}"
: "${WORKFORCE_POOL:?}" "${WORKFORCE_PROVIDER:?}" "${WIF_LOGIN_CONFIG:?}"

gcloud config configurations create "${UNIVERSE_NAME}" 2>/dev/null || true
gcloud config configurations activate "${UNIVERSE_NAME}"
gcloud config set universe_domain "${UNIVERSE_API_DOMAIN}"

# NOTE: project and region are set AFTER login. `gcloud config set project`
# validates the project, which requires an active account.

AUDIENCE="locations/global/workforcePools/${WORKFORCE_POOL}/providers/${WORKFORCE_PROVIDER}"

mkdir -p "$(dirname "${WIF_LOGIN_CONFIG}")"
gcloud iam workforce-pools create-login-config "${AUDIENCE}" \
  --universe-cloud-web-domain="${UNIVERSE_WEB_DOMAIN}" \
  --universe-domain="${UNIVERSE_API_DOMAIN}" \
  --output-file="${WIF_LOGIN_CONFIG}" \
  --activate

echo
echo ">>> Browser will open. A 404 page is the correct outcome."
echo ">>> If you see 'Login successful', you hit public GCP: stop and re-check universe_domain."
echo

gcloud auth login --login-config="${WIF_LOGIN_CONFIG}"

# Separate call. Terraform and the client libraries need ADC and will not pick up the above.
gcloud auth application-default login --login-config="${WIF_LOGIN_CONFIG}"

# Now that there is an active account, these can be validated. Non-fatal: the
# project may not exist yet, and the eu0: prefix convention is still unconfirmed.
# Project FIRST: `gcloud config set compute/region` validates the region against
# the active project and fails with "required property [project] is not set".
if [[ -n "${PROJECT_ID:-}" ]]; then
  gcloud config set project "${PROJECT_ID}" \
    || echo "warn: could not set project '${PROJECT_ID}'. Check PROJECT_ID in .env.local against \`gcloud projects list\`."

  # ADC does not inherit the quota project. Terraform and the client libraries
  # will hit "quota exceeded" or "API not enabled" without this.
  gcloud auth application-default set-quota-project "${PROJECT_ID}" || true
fi
if [[ -n "${UNIVERSE_REGION:-}" ]]; then
  gcloud config set compute/region "${UNIVERSE_REGION}" || true
fi

echo
gcloud config list
echo
gcloud auth list
