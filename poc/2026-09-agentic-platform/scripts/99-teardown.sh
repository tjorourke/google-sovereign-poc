#!/usr/bin/env bash
# 99-teardown.sh — remove everything, in reverse dependency order.
#
# Deliberately NOT wired to a single flag: destroying the cluster and the Cloud
# SQL instance is slow and irreversible, and the KMS keys have prevent_destroy
# on them so a destroy will refuse rather than orphan encrypted data. Read the
# prompts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl tofu
load_env
assert_universe

WHAT="${1:-help}"

case "$WHAT" in
  workloads)
    step "removing the Solo stack, leaving the infrastructure"
    # agents holds the waypoint-governed path; istio-system holds the mesh.
    # istio-system LAST of the workload namespaces: deleting ztunnel while other
    # namespaces are still enrolled leaves their traffic unmediated mid-teardown.
    for ns in mcp model agents solo-enterprise agentregistry-system kagent agentgateway-system keycloak observability external-secrets cert-manager istio-system; do
      kc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      log "deleting ns/$ns"
    done
    ok "namespaces deleting in the background"
    ;;
  allowlist)
    step "removing the Autopilot allowlist plumbing"
    # The synchroniser is the only thing that can create or remove a
    # WorkloadAllowlist, so it goes first; the allowlists disappear with it.
    kc delete allowlistsynchronizer istio-ambient --ignore-not-found >/dev/null 2>&1 || true
    ok "AllowlistSynchronizer removed"
    # Reset the cluster to GKE-managed allowlists only. gke://* must be passed
    # explicitly: an empty value disables every allowlist including the defaults.
    if gcloud container clusters update "${CLUSTER_NAME:-agentic}" \
         --location "${UNIVERSE_REGION:?}" \
         --autopilot-privileged-admission='gke://*' >/dev/null 2>&1; then
      ok "cluster reset to gke://* (took ~20 minutes)"
    else
      warn "could not reset the cluster's allowlist paths; check by hand"
    fi
    log "the org policy is left in place on purpose: it is organisation-scoped,"
    log "harmless without a cluster referencing it, and a rebuild reuses it."
    ;;
  infra)
    warn "this destroys the cluster, Cloud SQL, the buckets and the network."
    warn "KMS keys have prevent_destroy — tofu will refuse rather than orphan"
    warn "anything encrypted with them. Remove them by hand if you really mean to."
    read -r -p "type the project id to confirm ($PROJECT_ID): " CONFIRM
    [[ "$CONFIRM" == "$PROJECT_ID" ]] || die "aborted"
    cd "$TOFU_DIR"
    tofu destroy -input=false -var-file="profiles/${TOFU_PROFILE:-gcd-autopilot}.tfvars" -var stage=edge
    ;;
  all)
    "$0" workloads
    step "waiting 60s for namespaces to finish deleting (LB and NEG cleanup)"
    sleep 60
    "$0" infra
    ;;
  *)
    cat >&2 <<EOF
usage: 99-teardown.sh <workloads|infra|all>

  workloads  delete the Kubernetes namespaces, keep the cloud infrastructure.
             Do this first — it lets the LoadBalancers and NEGs clean up, which
             otherwise blocks the network destroy.
  allowlist  remove the AllowlistSynchronizer and reset the cluster's
             allowlist paths. Do this before `infra`, and note the ORG POLICY is
             left alone deliberately: it is organisation-scoped, survives
             teardown, and a new cluster in the same org inherits it.
  infra      tofu destroy. Prompts for the project id.
  all        both, in order, with a pause between.

Orphans worth checking afterwards, because a failed LB delete leaves them:
  gcloud compute forwarding-rules list --project '$PROJECT_ID'
  gcloud compute addresses list       --project '$PROJECT_ID'
  gcloud compute network-endpoint-groups list --project '$PROJECT_ID'
EOF
    ;;
esac
