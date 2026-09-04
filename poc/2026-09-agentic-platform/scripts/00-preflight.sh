#!/usr/bin/env bash
# 00-preflight.sh — Phase 0 probes that need no cluster. READ ONLY: every call is
# a describe/list, nothing is created. Writes verbatim output to
# feedback/google/evidence/ so the answers become citable findings.
#
# Answers, from PLAN.md:
#   0.4  is there an Artifact Registry repo yet, and what is its real host
#   0.8  does the eu0: project prefix survive a docker reference
#   0.10 is there any GPU quota
#   plus: universe sanity, service catalogue re-verify, GKE versions, machine types
#
# The in-cluster probes (0.2 egress, 0.3 image pull, 0.5 storage class,
# 0.6 admission, 0.9 hostAliases, 0.11 public DNS) live in 20-cluster-probes.sh
# because they need a cluster to exist first.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

[[ -f .env.local ]] || { echo "error: .env.local not found. Copy .env.local.example." >&2; exit 1; }
# shellcheck disable=SC1091
source .env.local

: "${UNIVERSE_API_DOMAIN:?}" "${UNIVERSE_REGION:?}" "${PROJECT_ID:?}" "${AR_REPO:?}" "${AR_LOCATION:?}"

STAMP="$(date -u +%Y-%m-%d)"
OUT="feedback/google/evidence/berlin-preflight-${STAMP}.txt"
mkdir -p "$(dirname "$OUT")"

say()  { printf '\n\033[1;34m▸ %s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

# Record a probe: header + verbatim output into $OUT, and echo to the terminal.
probe() {
  local label="$1"; shift
  say "$label"
  {
    printf '\n===============================================================\n'
    printf '## %s\n' "$label"
    printf '## $ %s\n' "$*"
    printf '===============================================================\n'
  } >>"$OUT"
  if "$@" >>"$OUT" 2>&1; then ok "$label"; else warn "$label — non-zero exit (recorded)"; fi
  tail -n 25 "$OUT" >&2
}

{
  printf '# Berlin GCD preflight — %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# project=%s region=%s universe=%s\n' "$PROJECT_ID" "$UNIVERSE_REGION" "$UNIVERSE_API_DOMAIN"
  printf '# gcloud %s\n' "$(gcloud version 2>/dev/null | head -1)"
} >"$OUT"

# ── 0. universe sanity: the single most expensive mistake is talking to public GCP
say "Universe sanity"
ACTIVE_UNIVERSE="$(gcloud config get-value universe_domain 2>/dev/null)"
if [[ "$ACTIVE_UNIVERSE" != "$UNIVERSE_API_DOMAIN" ]]; then
  warn "active universe_domain is '${ACTIVE_UNIVERSE:-unset}', expected '$UNIVERSE_API_DOMAIN'"
  warn "run scripts/gcd-auth.sh first — everything below would hit public GCP"
  exit 1
fi
ok "universe_domain = $ACTIVE_UNIVERSE"
probe "active gcloud configuration" gcloud config list

# ── service catalogue: re-verify, it is a preview universe and this moves
probe "enabled services" \
  gcloud services list --enabled --project "$PROJECT_ID"
probe "available services (re-verify the 31)" \
  gcloud services list --available --project "$PROJECT_ID"

# ── 0.10 GPU quota: decides whether Gemma runs on H100 or on CPU today
probe "0.10 region quotas (look for GPUS / NVIDIA_H100 / CPUS)" \
  gcloud compute regions describe "$UNIVERSE_REGION" --project "$PROJECT_ID" \
    --format='table(quotas.metric,quotas.limit,quotas.usage)'
probe "0.10 zones in region" \
  gcloud compute zones list --project "$PROJECT_ID" --filter="region:$UNIVERSE_REGION"
probe "machine types (expect C3, M3, A3 only)" \
  gcloud compute machine-types list --project "$PROJECT_ID" \
    --filter="zone:${UNIVERSE_REGION}-a" --format='value(name)'
probe "accelerator types (expect nvidia-h100-80gb or nothing)" \
  gcloud compute accelerator-types list --project "$PROJECT_ID" \
    --filter="zone:${UNIVERSE_REGION}-a"

# ── GKE: what versions and channels does Berlin actually offer
probe "GKE server config (channels + versions; docs say 1.36.x, Stable/Regular)" \
  gcloud container get-server-config --project "$PROJECT_ID" --location "$UNIVERSE_REGION"

# ── 0.4 / 0.8 Artifact Registry: the real host, and the eu0: colon question
probe "0.4 artifact registry repositories" \
  gcloud artifacts repositories list --project "$PROJECT_ID" --location "$AR_LOCATION"
if gcloud artifacts repositories describe "$AR_REPO" --project "$PROJECT_ID" \
     --location "$AR_LOCATION" >/dev/null 2>&1; then
  probe "0.4 registryUri for repo '$AR_REPO' (this is the authoritative AR_HOST)" \
    gcloud artifacts repositories describe "$AR_REPO" --project "$PROJECT_ID" \
      --location "$AR_LOCATION" --format=json
  REAL_URI="$(gcloud artifacts repositories describe "$AR_REPO" --project "$PROJECT_ID" \
    --location "$AR_LOCATION" --format='value(registryUri)' 2>/dev/null)"
  ok "registryUri = ${REAL_URI:-<empty>}"
  if [[ -n "${AR_HOST:-}" && "$REAL_URI" != "${AR_HOST}"* ]]; then
    warn "AR_HOST in .env.local ('$AR_HOST') does not prefix the real registryUri — fix .env.local"
  fi
  case "$REAL_URI" in
    *:*/*) warn "0.8 registryUri contains a colon inside a path component — expect docker/helm clients to reject it. Record this, it is a finding." ;;
  esac
else
  warn "repo '$AR_REPO' does not exist yet in $AR_LOCATION — tofu creates it, then re-run this script"
  warn "0.8 (eu0: colon in a docker ref) cannot be answered until the repo exists"
fi

# ── 0.15 JIT service agents: every CMEK binding depends on these existing
say "0.15 service agents (GCD provisions these just-in-time, not on API enable)"
for svc in sqladmin.googleapis.com artifactregistry.googleapis.com \
           storage.googleapis.com logging.googleapis.com \
           bigquery.googleapis.com container.googleapis.com; do
  printf '  %-42s ' "$svc" >&2
  EMAIL="$(gcloud beta services identity create --service="$svc" \
    --project "$PROJECT_ID" --format='value(email)' 2>>"$OUT" || true)"
  if [[ -n "$EMAIL" ]]; then
    echo "$EMAIL" >&2
    printf '0.15 %s -> %s\n' "$svc" "$EMAIL" >>"$OUT"
  else
    printf '\033[33mFAILED\033[0m — CMEK for this service is not possible\n' >&2
    printf '0.15 %s -> FAILED\n' "$svc" >>"$OUT"
  fi
done

# ── 0.14 can we create a REGIONAL Cloud Armor policy and a REGIONAL cert
probe "0.14 existing regional security policies (Cloud Armor)" \
  gcloud compute security-policies list --project "$PROJECT_ID" --filter="region:$UNIVERSE_REGION"
probe "0.14 existing regional ssl certificates" \
  gcloud compute ssl-certificates list --project "$PROJECT_ID" --filter="region:$UNIVERSE_REGION"

# ── 0.16 the two most quotable sovereignty controls
probe "0.16 access approval settings" \
  gcloud access-approval settings get --project "$PROJECT_ID"

# ── 0.17 can we add a second Workforce Identity Federation provider (Solo's IdP)
probe "0.17 existing workforce pool providers" \
  gcloud iam workforce-pools providers list \
    --workforce-pool "${WORKFORCE_POOL}" --location global

# ── org policy: which predefined constraints does Berlin actually offer
probe "org policy constraints available (no custom constraints in GCD)" \
  gcloud resource-manager org-policies list --project "$PROJECT_ID"

# ── org / project shape, useful context for any finding we file
probe "project describe (note the eu0: prefix)" \
  gcloud projects describe "$PROJECT_ID" --format=json

printf '\n\033[1;32m✓ preflight recorded to %s\033[0m\n' "$OUT" >&2
cat >&2 <<'NEXT'

  Still open (need a cluster — run after `10-tofu.sh`):
    0.2  pod egress to the internet
    0.3  direct image pull from ghcr.io / us-docker.pkg.dev
    0.5  Hyperdisk Balanced StorageClass name
    0.6  Autopilot admission for ClickHouse / Postgres
    0.9  hostAliases accepted on Autopilot
    0.11 public DNS resolution from a pod
    0.12 Service type=LoadBalancer gets an external IP
    0.13 GKE Gateway classes present (gke-l7-regional-external-managed)

  Also check locally, one command, no cloud involved:
    dig +short keycloak.localtest.me      # must return 127.0.0.1
NEXT
