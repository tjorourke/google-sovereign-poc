#!/usr/bin/env bash
# 45-telemetry.sh — the Solo Enterprise management chart: ClickHouse, the OTel
# collectors, and the Enterprise UI (Dashboard, Agents, Tracing, Access Policies).
#
# On public GCP this chart is a convenience. On GCD it is the ONLY agent
# observability that exists, because Cloud Monitoring here cannot ingest custom,
# Prometheus or OpenTelemetry metrics at all, and Cloud Logging cannot do
# log-based metrics or sink to BigQuery/GCS. That makes this chart a load-bearing
# part of the sovereign story rather than a nice-to-have.
#
# The trace path: agent -> OTLP -> telemetry collector -> ClickHouse -> Tracing tab.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl helm
load_env
assert_universe

NS=solo-enterprise
VERSION="${SOLO_MGMT_ENT_VERSION:-0.4.3}"
CHART="${SOLO_MGMT_CHART:-oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management}"
CLUSTER="${CLUSTER_NAME:-$(tofu_out cluster_name)}"

ENVF="$LAB_ROOT/deploy/.env.oidc"
[[ -f "$ENVF" ]] || die "no $ENVF — run 30-keycloak.sh first"
# shellcheck disable=SC1090
source "$ENVF"
: "${OIDC_ISSUER:?}"
[[ -n "${KAGENT_BACKEND_SECRET_ENC:-}" ]] && KAGENT_BACKEND_SECRET="$(kms_decrypt "$KAGENT_BACKEND_SECRET_ENC")"
: "${KAGENT_BACKEND_SECRET:?}"
: "${SOLO_LICENSE_KEY:?}"

step "namespace"
kc create ns "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

step "UI backend OIDC secret"
kc -n "$NS" create secret generic ui-backend-oidc-secret \
  --from-literal=clientSecret="$KAGENT_BACKEND_SECRET" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── ClickHouse persistence: an Autopilot decision, not a preference ──────────
# GCD has Hyperdisk Balanced only. If probe 0.5 found a default StorageClass and
# 0.6 admitted a StatefulSet with a PVC, keep persistence on — losing trace
# history on every restart is a bad look in a customer template. Otherwise fall
# back to ephemeral, which is what the kind lab does.
CH_PERSIST="${CLICKHOUSE_PERSIST:-auto}"
if [[ "$CH_PERSIST" == "auto" ]]; then
  DEFAULT_SC="$(kc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)"
  if [[ -n "$DEFAULT_SC" ]]; then CH_PERSIST=true; else CH_PERSIST=false; fi
fi
if [[ "$CH_PERSIST" == "true" ]]; then
  ok "ClickHouse persistence ON (default StorageClass: ${DEFAULT_SC:-?})"
  CH_ARGS=(--set clickhouse.persistentVolume.enabled=true)
  [[ -n "${DEFAULT_SC:-}" ]] && CH_ARGS+=(--set clickhouse.persistentVolume.storageClass="$DEFAULT_SC")
else
  warn "ClickHouse persistence OFF — trace history is lost on restart"
  CH_ARGS=(--set clickhouse.persistentVolume.enabled=false)
fi

# The management chart ships ClickHouse with ephemeral-storage limited to 50Mi.
# ClickHouse writes its database to local disk, exceeds that, and Autopilot
# EVICTS the pod. The give-away is restarts=0 while the pod keeps reappearing:
# eviction recreates the pod rather than restarting the container, so nothing
# looks like it is crashing. Raise the floor.
CH_ARGS+=(
  --set clickhouse.resources.requests.ephemeral-storage=2Gi
  --set clickhouse.resources.limits.ephemeral-storage=8Gi
)
step "solo-enterprise management $VERSION"
helm --kube-context "$(kube_context)" upgrade --install solo-mgmt "$CHART" \
  -n "$NS" --version "$VERSION" \
  --set cluster="$CLUSTER" \
  --set products.kagent.enabled=true \
  --set products.kagent.namespace=kagent \
  --set products.agentgateway.namespace=agentgateway-system \
  --set licensing.licenseKey="$SOLO_LICENSE_KEY" \
  "${CH_ARGS[@]}" \
  --set oidc.issuer="$OIDC_ISSUER" \
  --set ui.frontend.oidc.clientId=kagent-ui \
  --set ui.backend.oidc.clientId=kagent-backend \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  >/dev/null
ok "chart applied"

step "waiting for the UI"
kc -n "$NS" rollout status deploy/solo-enterprise-ui --timeout=300s || {
  warn "UI not ready — it does OIDC discovery at startup. Check:"
  warn "  kubectl --context $(kube_context) -n $NS logs deploy/solo-enterprise-ui | tail -40"
  die "solo-enterprise-ui did not become ready"
}
ok "Enterprise UI ready"

cat >&2 <<EOF

  ClickHouse + OTel collectors + Enterprise UI are up in '$NS'.

  Worth saying out loud in the write-up: on GCD this stack is not optional.
  Cloud Monitoring cannot ingest custom, Prometheus or OTel metrics, and Cloud
  Logging cannot create log-based metrics or sink to BigQuery/GCS. Without this
  chart plus the Prometheus/Grafana from 25-cluster-baseline.sh, a GCD customer
  has no agent observability at all.

  Next: ./scripts/50-agentregistry.sh
EOF
