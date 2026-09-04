#!/usr/bin/env bash
# 08-enable-apis.sh — enable the services the template needs.
#
# A fresh GCD project ships with only 9 services enabled (bigquery x3, cloudapis,
# logging, monitoring, serviceusage, storage x2). Everything else — including
# compute and container — has to be enabled explicitly, and `tofu apply` fails
# with "Compute Engine API has not been used in project ... before or it is
# disabled" if you skip this.
#
# Two GCD notes:
#   - Service NAMES keep the public googleapis.com form even inside the
#     universe. Only endpoint URLs take the .goog domain. Do not rewrite these.
#   - Enabling is async and propagation is uneven: after the operation reports
#     success, `gcloud compute zones list` worked immediately while
#     `gcloud compute regions list` and `machine-types list` still returned
#     "API has not been used" for a while. So this script waits on a real read.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud
load_env
assert_universe

# Only services that exist in Berlin's catalogue. Anything not in the 31 will
# fail the whole batch, so keep this list in step with
# feedback/google/evidence/berlin-services-*.txt.
APIS=(
  # infrastructure
  compute.googleapis.com
  container.googleapis.com
  artifactregistry.googleapis.com
  sqladmin.googleapis.com
  autoscaling.googleapis.com
  # keys and secrets-by-envelope
  cloudkms.googleapis.com
  # networking
  dns.googleapis.com
  networksecurity.googleapis.com
  networkconnectivity.googleapis.com
  servicedirectory.googleapis.com
  # data and audit
  pubsub.googleapis.com
  # identity
  iam.googleapis.com
  iamcredentials.googleapis.com
  sts.googleapis.com
  # governance
  orgpolicy.googleapis.com
  essentialcontacts.googleapis.com
  accesscontextmanager.googleapis.com
  cloudresourcemanager.googleapis.com
)

step "currently enabled"
BEFORE="$(gcloud services list --enabled --project "$PROJECT_ID" --format='value(config.name)' 2>/dev/null | sort)"
printf '%s\n' "$BEFORE" | sed 's/^/  /' >&2
log "$(printf '%s\n' "$BEFORE" | grep -c . ) enabled"

step "enabling ${#APIS[@]} services (one batched operation)"
gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"
ok "operation finished"

# Propagation is uneven. Wait on an actual compute read rather than trusting the
# operation, because tofu will fail on exactly this.
step "waiting for the Compute Engine API to answer a real read"
for i in $(seq 1 40); do
  if gcloud compute zones list --project "$PROJECT_ID" --format='value(name)' >/dev/null 2>&1; then
    ok "compute answering (attempt $i)"
    break
  fi
  sleep 15
done
gcloud compute zones list --project "$PROJECT_ID" --format='value(name)' >/dev/null 2>&1 \
  || die "Compute Engine API still not answering after 10m — check the console"

step "now enabled"
gcloud services list --enabled --project "$PROJECT_ID" --format='value(config.name)' 2>/dev/null \
  | sort | sed 's/^/  /' >&2

cat >&2 <<EOF

  Note: 'gcloud compute regions list' and 'machine-types list' may keep
  returning "API has not been used" for several more minutes even once zones
  works. That is propagation, not a real failure. 'regions describe' and
  'project-info describe' come back sooner.

  Next: ./scripts/00-preflight.sh   (re-run it — the compute probes need this)
EOF
