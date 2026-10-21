#!/usr/bin/env bash
# 35-gcs.sh — the Cloud Storage bucket that holds Substrate's actor snapshots.
#
# Substrate's object-store plugins (a sidecar in atelet, another in
# ate-api-server) read and write snapshots with the pod's own credentials:
# Workload Identity Federation for GKE. There is no key (GCD's org policy
# forbids service-account keys) and no Google service account, only bucket
# roles granted to the two Kubernetes ServiceAccounts. yaml/substrate-values.yaml
# selects the GCS backend; yaml/agents.yaml and yaml/egress.yaml point each
# Harness and SandboxTemplate at this bucket. Idempotent.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gcloud
assert_session

BUCKET="${SNAPSHOT_BUCKET:-agentic-ate-snapshots}"
POOL="$(gcloud container clusters describe "$CLUSTER_NAME" --location "$UNIVERSE_REGION" \
  --format='value(workloadIdentityConfig.workloadPool)')"
[[ -n "$POOL" ]] || die "no Workload Identity pool on $CLUSTER_NAME"

step "bucket gs://$BUCKET in $UNIVERSE_REGION"
if gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  ok "exists"
else
  gcloud storage buckets create "gs://$BUCKET" --location "$UNIVERSE_REGION" \
    --uniform-bucket-level-access --public-access-prevention >/dev/null \
    || die "could not create gs://$BUCKET"
  ok "created"
fi

step "object roles for the object-store plugins (Workload Identity, pool $POOL)"
# The member keeps the literal iam.googleapis.com host inside the universe.
for ksa in atelet ate-api-server; do
  member="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/subject/ns/ate-system/sa/$ksa"
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member "$member" \
    --role roles/storage.objectUser >/dev/null || die "could not grant ate-system/$ksa"
  ok "ate-system/$ksa: roles/storage.objectUser"
done
