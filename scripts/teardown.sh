#!/usr/bin/env bash
# teardown.sh — take the environment down, in one command.
#
#   ./scripts/teardown.sh              destroy the CLUSTER (default)
#   ./scripts/teardown.sh --all        destroy everything, including Cloud SQL
#   ./scripts/teardown.sh --dry-run    show what would be destroyed, change nothing
#   ./scripts/teardown.sh --no-preclean  skip deleting load balancers and PVCs
#                                        first (orphans them; see preclean_cluster)
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

ALL=0; DRY=0; PRECLEAN=1
for a in "$@"; do
  case "$a" in
    --all)         ALL=1 ;;
    --dry-run)     DRY=1 ;;
    --no-preclean) PRECLEAN=0 ;;
    *) red "unknown flag: $a"; exit 64 ;;
  esac
done

# Deleting a GKE cluster does not delete the cloud resources its controllers
# created: a LoadBalancer Service leaves its forwarding rule and address, a
# Gateway its NEGs, and a PVC its Hyperdisk. Those controllers only clean up
# while they are running, so remove the objects first and let them. On
# 2026-10-21 this left 6 load balancers and 4 disks (one of them 200 GiB) to be
# cleaned by hand.
preclean_cluster() {
  local kcfg cluster="${CLUSTER_NAME:-agentic}"
  kcfg="$(mktemp)"
  if ! KUBECONFIG="$kcfg" gcloud container clusters get-credentials "$cluster" \
      --location "$UNIVERSE_REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
    ylw "  cluster $cluster not reachable; skipping the pre-clean"
    rm -f "$kcfg"; return 0
  fi
  local k=(kubectl --kubeconfig "$kcfg" --request-timeout=30s)
  "${k[@]}" delete gateway --all -A --wait=false >/dev/null 2>&1 || true
  "${k[@]}" get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r ns name; do
        [[ -n "$name" ]] && "${k[@]}" -n "$ns" delete svc "$name" --wait=false >/dev/null 2>&1
      done
  # Deleting the namespaces removes PVC consumers and then the PVCs; the CSI
  # driver deletes each disk (reclaimPolicy Delete) while it still can.
  "${k[@]}" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -v -E '^(default|kube-.*|gke-.*|gmp-.*)$' \
    | while read -r ns; do "${k[@]}" delete ns "$ns" --wait=false >/dev/null 2>&1; done
  local i lbs pvs
  for i in $(seq 1 36); do
    lbs="$("${k[@]}" get svc -A --field-selector spec.type=LoadBalancer --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    pvs="$("${k[@]}" get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$lbs" == 0 && "$pvs" == 0 ]] && break
    sleep 5
  done
  [[ "$lbs" == 0 && "$pvs" == 0 ]] \
    && grn "  ok load balancers and disks released" \
    || ylw "  still present after 3 minutes: $lbs LoadBalancer Service(s), $pvs PV(s); check for orphans afterwards"
  rm -f "$kcfg"
}

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

if [[ "$PRECLEAN" -eq 1 ]]; then
  hdr "Releasing load balancers and disks while the cluster's controllers can"
  preclean_cluster
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
  # Only 08 (enable APIs) still holds -- that is project-scoped and a cluster
  # destroy does not touch it.
  #
  # 10 must NOT be kept. It is tempting to, because it also builds the VPC, the
  # Cloud SQL instance and the buckets, and those did survive -- but it builds
  # the CLUSTER too, and the cluster is precisely what was just destroyed.
  # Marking it done skips cluster creation, and the standup then fails at phase
  # 20 against a cluster that does not exist. Re-running it is cheap and correct:
  # tofu apply no-ops on the surviving resources and recreates only the cluster.
  printf '08\n' > "$LAB/deploy/.run-all-state"
  grn "  ok phase 08 kept; everything else, cluster included, will re-run"
fi

hdr "DONE"
cat <<EOF

  Stand it back up with:

    ./scripts/deploy-e2e.sh

EOF
