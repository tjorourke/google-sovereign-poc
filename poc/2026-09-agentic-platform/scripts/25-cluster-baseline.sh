#!/usr/bin/env bash
# 25-cluster-baseline.sh — the three platform components that are OPTIONAL on
# public GCP and MANDATORY on GCD, because the managed service they would
# otherwise use does not exist here.
#
#   cert-manager      no Certificate Manager, no privateca, no Google-managed
#                     certs, and Cloud DNS has no public zones -> ACME is
#                     impossible by either challenge type. So east-west certs
#                     come from a self-hosted internal CA.
#   External Secrets  no Secret Manager. ESO with a Cloud KMS backend is the
#                     nearest thing to a managed secret store.
#   Prometheus+Grafana  Cloud Monitoring cannot ingest custom, Prometheus or
#                     OTel metrics at all. Google's own docs say "use PromQL
#                     and Grafana". Without this the Solo stack has NO metrics.
#
# Everything installs from the mirrored Artifact Registry if 0.3 said direct
# pulls fail, otherwise from upstream. IMAGE_REGISTRY drives that.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl helm
load_env
assert_universe

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
ESO_VERSION="${ESO_VERSION:-0.10.5}"
KPS_VERSION="${KPS_VERSION:-65.5.1}"

# ── 1. cert-manager + a self-signed internal CA ──────────────────────────────
step "cert-manager $CERT_MANAGER_VERSION"
# 5m is not enough on Autopilot. cert-manager's startupapicheck Job waits for the
# webhook to serve, and on a cold cluster Autopilot is still provisioning nodes,
# so the Job sits Pending and helm gives up:
#   Error: failed post-install: resource Job/cert-manager/cert-manager-startupapicheck
#          not ready. status: InProgress
# The install itself is fine; only the post-install gate times out.
helm --kube-context "$(kube_context)" upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "$CERT_MANAGER_VERSION" \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 15m
ok "cert-manager installed"

step "internal CA (there is no ACME path in GCD, so this is the east-west root)"
kc apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-root
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agentic-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: agentic-internal-ca
  secretName: agentic-ca-tls
  duration: 87600h    # 10y — a lab root; a customer would use their own PKI
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-root
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: agentic-ca
spec:
  ca:
    secretName: agentic-ca-tls
YAML
kc -n cert-manager wait --for=condition=Ready certificate/agentic-ca --timeout=120s
ok "internal CA ready (ClusterIssuer/agentic-ca)"

# ── 2. External Secrets Operator, backed by Cloud KMS ────────────────────────
# The honest framing: GCD has no Secret Manager, so there is no managed store
# for ESO to read from. What we get instead is envelope encryption — the
# ciphertext lives in a Kubernetes Secret and Cloud KMS holds the key. That
# protects the value in git and in our own storage. It does NOT protect it in
# etcd, because GKE here does not support application-layer Secret encryption.
step "External Secrets Operator $ESO_VERSION"
helm --kube-context "$(kube_context)" upgrade --install external-secrets external-secrets \
  --repo https://charts.external-secrets.io \
  --version "$ESO_VERSION" \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m
ok "ESO installed"

if [[ -n "${KMS_ENVELOPE_KEY:-}" ]]; then
  KSA_SA="$(cd "$TOFU_DIR" && tofu output -json service_account_emails 2>/dev/null | jq -r '.externalsecrets // empty')"
  if [[ -n "$KSA_SA" ]]; then
    kc -n external-secrets annotate serviceaccount external-secrets \
      "iam.gke.io/gcp-service-account=$KSA_SA" --overwrite >/dev/null
    ok "ESO ServiceAccount bound to $KSA_SA via Workload Identity"
  else
    warn "no externalsecrets service account in tofu output — run 10-tofu.sh apply"
  fi
else
  warn "KMS_ENVELOPE_KEY unset — envelope encryption unavailable until 10-tofu.sh has run"
fi

# ── 3. Prometheus + Grafana. Not optional here. ──────────────────────────────
step "kube-prometheus-stack $KPS_VERSION (Cloud Monitoring cannot ingest our metrics)"
helm --kube-context "$(kube_context)" upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$KPS_VERSION" \
  -n observability --create-namespace \
  --set grafana.enabled=true \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD:-admin}" \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set alertmanager.enabled=false \
  --wait --timeout 15m
ok "Prometheus + Grafana installed in namespace observability"

cat >&2 <<EOF

  Baseline is in. Three components, three absent Google services:
    cert-manager       -> no Certificate Manager / privateca / ACME
    external-secrets   -> no Secret Manager
    kube-prometheus    -> Cloud Monitoring cannot ingest custom/Prom/OTel metrics

  Grafana:  kubectl --context $(kube_context) -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80

  Next: ./scripts/30-keycloak.sh
EOF
