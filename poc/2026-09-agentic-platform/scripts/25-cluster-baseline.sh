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
clear_failed_release cert-manager cert-manager
# TWO Autopilot-specific settings here, both mandatory:
#
# global.leaderElection.namespace — cert-manager's controller and cainjector
# default their leader-election lease to kube-system, and Autopilot REFUSES
# writes to it:
#   leases.coordination.k8s.io is forbidden: ... GKE Warden authz
#   [denied by managed-namespaces-limitation]: the namespace "kube-system" is
#   managed and the request's verb "create" is denied
# The cainjector then never gains leadership, so it never writes the CA bundle
# into the ValidatingWebhookConfiguration, and every cert-manager resource is
# rejected with "x509: certificate signed by unknown authority". All three pods
# report Running and Ready throughout, so nothing points at leader election.
#
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
  --set global.leaderElection.namespace=cert-manager \
  --wait --timeout 15m
ok "cert-manager installed"

# helm --wait returning does NOT mean cert-manager's validating webhook will
# accept resources yet. The cainjector still has to write the CA bundle into the
# ValidatingWebhookConfiguration, and until it does every apply is rejected:
#   failed calling webhook "webhook.cert-manager.io": tls: failed to verify
#   certificate: x509: certificate signed by unknown authority
# Nothing in cert-manager's own readiness reflects this, so probe the webhook
# with a server-side dry run until it actually answers.
step "waiting for cert-manager's webhook to accept resources"
CM_READY=0
for _ in $(seq 1 60); do
  if kc apply --dry-run=server -f - >/dev/null 2>&1 <<'PROBE'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: webhook-readiness-probe
spec:
  selfSigned: {}
PROBE
  then CM_READY=1; break; fi
  sleep 5
done
[[ "$CM_READY" -eq 1 ]] && ok "webhook is serving" \
  || die "cert-manager's webhook never became ready. Check:
    kubectl -n cert-manager logs deploy/cert-manager-cainjector
    kubectl get validatingwebhookconfiguration cert-manager-webhook -o yaml"

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
# kube-prometheus-stack needs REAL de-scoping on Autopilot. Two groups of its
# defaults are impossible here, and both fail the whole release:
#
# 1. Control-plane scrapers. The chart creates or patches Services in
#    kube-system for coredns, etcd, kube-controller-manager, kube-scheduler and
#    kube-proxy. Autopilot refuses every write to that namespace:
#      services "kube-prometheus-stack-coredns" is forbidden ... GKE Warden authz
#      [denied by managed-namespaces-limitation]: the namespace "kube-system" is
#      managed and the request's verb "patch" is denied
#    No loss: on Autopilot the control plane is Google-managed and its metrics
#    are not exposed to scrape in the first place.
#
# 2. node-exporter. It is a privileged DaemonSet and Autopilot rejects it:
#      [denied by autogke-disallow-hostnamespaces]: enabling hostPID is not
#      allowed in Autopilot. enabling hostNetwork is not allowed in Autopilot.
#      [denied by autogke-no-write-mode-hostpath]: hostPath volume proc ... /proc
#      ... sys ... /sys ... root ... / ... Allowed path prefixes are [/var/log/]
#    It COULD be admitted with a WorkloadAllowlist (see 62/63), but node-level
#    metrics on Autopilot are Google's responsibility, so it is not worth the
#    privilege. GKE already exports node metrics.
#
# What remains is what actually matters here: kube-state-metrics, Prometheus
# itself, and Grafana, scraping our own workloads' ServiceMonitors. That is the
# gap Cloud Monitoring leaves, since it cannot ingest custom or OTel metrics.
step "kube-prometheus-stack $KPS_VERSION (Cloud Monitoring cannot ingest our metrics)"
clear_failed_release kube-prometheus-stack observability
helm --kube-context "$(kube_context)" upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --set kubeEtcd.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false \
  --set coreDns.enabled=false \
  --set kubeDns.enabled=false \
  --set nodeExporter.enabled=false \
  --set prometheus-node-exporter.enabled=false \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$KPS_VERSION" \
  -n observability --create-namespace \
  --set grafana.enabled=true \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD:-admin}" \
  `# Autopilot DEFAULTS any container that does not request cpu/memory, and it` \
  `# defaults generously: the Grafana pod has three containers and the chart` \
  `# sets resources on none of them, so it was admitted requesting 1500m CPU` \
  `# and 6Gi memory. On GCD that is expensive -- GKE here is C3-only and this` \
  `# project's C3_CPUS quota is 24, so Grafana alone was taking 6% of the` \
  `# cluster's entire CPU budget and starving later phases of schedulable` \
  `# capacity. Ask for what it actually needs.` \
  --set grafana.resources.requests.cpu=100m \
  --set grafana.resources.requests.memory=256Mi \
  --set grafana.sidecar.resources.requests.cpu=50m \
  --set grafana.sidecar.resources.requests.memory=128Mi \
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
