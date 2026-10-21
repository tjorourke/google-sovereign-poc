#!/usr/bin/env bash
# 10-cluster.sh — credentials for the rebuilt cluster, and proof that it serves
# what Agent Substrate needs before anything is installed on it.
#
# The cluster itself is OpenTofu (infra/tofu, profile gcd-autopilot). This lab's
# requirements are in that profile: GKE 1.36.4, the two certificate beta APIs
# enabled AT CREATION (GKE ignores a later change), and the Substrate allowlist
# paths. Recreate it with:
#
#   cd infra/tofu && tofu plan -var-file=profiles/gcd-autopilot.tfvars -var stage=platform \
#     -replace='module.cluster_autopilot[0].google_container_cluster.this' \
#     -target=module.cluster_autopilot -target=module.iam -out=replace.tfplan
#   tofu apply replace.tfplan
#
# The symptom of a cluster created without the APIs is an install that hangs at
# "Waiting for podcertificate ClusterTrustBundles"; there is no in-place fix.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gcloud kubectl
assert_session

OUT="$LAB_ROOT/evidence/cluster-$(date -u +%Y-%m-%d).txt"

step "credentials for $CLUSTER_NAME into $KUBECONFIG"
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --location "$UNIVERSE_REGION" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || die "get-credentials failed for $CLUSTER_NAME"
assert_kube
ok "$(kubectl config current-context)"

step "cluster configuration"
gcloud container clusters describe "$CLUSTER_NAME" --location "$UNIVERSE_REGION" \
  --project "$PROJECT_ID" --format=json > "$LAB_ROOT/deploy/cluster.json"
python3 - "$LAB_ROOT/deploy/cluster.json" <<'EOF' | tee "$OUT"
import json, sys
c = json.load(open(sys.argv[1]))
print("version:            ", c.get("currentMasterVersion"))
print("channel:            ", c.get("releaseChannel", {}).get("channel"))
print("autopilot:          ", c.get("autopilot", {}).get("enabled"))
print("beta APIs:          ", c.get("enableK8sBetaApis", {}).get("enabledApis", []))
print("allowlist paths:    ", c.get("autopilot", {}).get("privilegedAdmissionConfig", {}).get("allowlistPaths", []))
print("workload pool:      ", c.get("workloadIdentityConfig", {}).get("workloadPool"))
EOF

step "certificate APIs Substrate needs"
RES="$(kubectl api-resources --api-group=certificates.k8s.io -o wide 2>/dev/null)"
printf '%s\n' "$RES" | tee -a "$OUT" | sed 's/^/    /'
for r in podcertificaterequests clustertrustbundles; do
  printf '%s\n' "$RES" | awk '{print $1}' | grep -qx "$r" \
    && ok "$r served" \
    || die "$r is NOT served. The cluster must be recreated with it in k8s_beta_apis."
done

step "nodes"
kubectl get nodes -L cloud.google.com/machine-family,node.kubernetes.io/instance-type,cloud.google.com/gke-accelerator 2>&1 | tee -a "$OUT" | sed 's/^/    /'
ok "evidence: ${OUT#"$REPO_ROOT"/}"
