#!/usr/bin/env bash
# teardown.sh — take the environment down, in one command.
#
#   ./scripts/teardown.sh              destroy the CLUSTER (default)
#   ./scripts/teardown.sh --all        destroy everything, including Cloud SQL
#   ./scripts/teardown.sh --dry-run    show what would be destroyed, change nothing
#
# WHAT "TEARDOWN" MEANS HERE, AND WHY THE DEFAULT IS THE CLUSTER
# Destroying the cluster destroys every piece of state this project actually
# builds: the mesh, the allowlists, the agents, the policies, the UIs, the
# certificates. What it leaves is the slow, boring infrastructure -- Cloud SQL,
# the KMS keyring, the VPC, the buckets -- which takes far longer to rebuild,
# holds no in-cluster assumptions, and in the case of KMS is protected by
# prevent_destroy anyway.
#
# That default is also what makes the rebuild a real test: everything the
# scripts assume about a cluster is gone, so anything that only works because
# it was left over from last time will fail loudly.
#
# --all additionally destroys Cloud SQL and its databases. Use it when you want
# a genuinely empty project; expect the rebuild to take considerably longer.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SD/.." && pwd)"
LAB="$REPO/poc/2026-09-agentic-platform"
TOFU_DIR="$REPO/infra/tofu"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
hdr(){ printf '\n\033[1;34m══ %s\033[0m\n' "$*"; }

ALL=0; DRY=0
for a in "$@"; do
  case "$a" in
    --all)     ALL=1 ;;
    --dry-run) DRY=1 ;;
    *) red "unknown flag: $a"; exit 64 ;;
  esac
done

# shellcheck disable=SC1091
source "$REPO/.env.local"
export GOOGLE_CLOUD_UNIVERSE_DOMAIN="$UNIVERSE_API_DOMAIN"

gcloud auth print-access-token >/dev/null 2>&1 || {
  red "no valid credential. Authenticate, then re-run:"
  red "  ./scripts/gcd-auth.sh"
  exit 75
}

PROFILE="${TOFU_PROFILE:-gcd-autopilot}"
VARFILE="profiles/${PROFILE}.tfvars"
TARGET='module.cluster_autopilot[0].google_container_cluster.this'

hdr "What this will destroy"
if [[ "$ALL" -eq 1 ]]; then
  ylw "  EVERYTHING, including Cloud SQL and its databases."
  ylw "  KMS keys are protected by prevent_destroy and will survive."
else
  echo "  The GKE cluster and everything running in it."
  echo "  KEPT: Cloud SQL, KMS, the VPC, the buckets, the DNS zone."
  echo "  (use --all to destroy those too)"
fi

cd "$TOFU_DIR" || { red "no $TOFU_DIR"; exit 1; }

hdr "Plan"
if [[ "$ALL" -eq 1 ]]; then
  tofu plan -destroy -input=false -var-file="$VARFILE" -var "stage=platform" -no-color 2>&1 \
    | grep -E '^Plan:|will be destroyed' | sed 's/^/  /' | head -30
else
  tofu plan -destroy -input=false -var-file="$VARFILE" -var "stage=platform" \
    -target="$TARGET" -no-color 2>&1 \
    | grep -E '^Plan:|will be destroyed' | sed 's/^/  /' | head -20
fi

if [[ "$DRY" -eq 1 ]]; then
  hdr "Dry run — nothing was changed"
  exit 0
fi

hdr "Destroying (this takes ~10 minutes)"
if [[ "$ALL" -eq 1 ]]; then
  tofu destroy -input=false -auto-approve -var-file="$VARFILE" -var "stage=platform" \
    || { red "destroy failed"; exit 1; }
else
  # -target, so nothing outside the cluster's own dependency graph is touched.
  # The cluster's Workload Identity bindings go with it because they reference
  # its identity pool; that is correct, and the rebuild recreates them.
  tofu destroy -input=false -auto-approve -var-file="$VARFILE" -var "stage=platform" \
    -target="$TARGET" \
    || { red "destroy failed"; exit 1; }
fi
grn "  ok destroyed"

hdr "Forgetting the phase state"
# Otherwise the next standup skips phases whose work no longer exists.
if [[ "$ALL" -eq 1 ]]; then
  : > "$LAB/deploy/.run-all-state"
  grn "  ok all phases will re-run"
else
  # 08 (APIs) and 10 (infrastructure) still hold: the project and the surviving
  # infrastructure are untouched. Everything else was in the cluster.
  printf '08\n10\n' > "$LAB/deploy/.run-all-state"
  grn "  ok phases 08 and 10 kept; everything else will re-run"
fi

hdr "DONE"
cat <<EOF

  Stand it back up with:

    ./scripts/deploy-e2e.sh

EOF
