#!/usr/bin/env bash
# 50-agentregistry.sh — AgentRegistry Enterprise: the catalogue and governance
# plane for MCP servers, tools, agents and skills.
#
# GCD difference from the kind lab: instead of the chart's bundled Postgres
# StatefulSet, this points at the Cloud SQL Postgres Enterprise Plus instance
# provisioned by OpenTofu. Reasons, in order of weight:
#   1. Autopilot admission plus Hyperdisk-Balanced-only storage make a bundled
#      StatefulSet the riskier option (probe 0.6).
#   2. Cloud SQL is what a regulated customer would actually ship, so the
#      template should show that, not a demo Postgres in a pod.
#   3. It exercises sqladmin, which is one of the more interesting things that
#      IS present in Berlin's catalogue.
#
# Cloud SQL caveats that shaped this: Enterprise Plus edition only, C3 machine
# types only, Private Service Connect (private services access does NOT exist
# in GCD), and IAM database authentication is SERVICE-ACCOUNT ONLY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl helm jq
load_env
assert_universe

NS=agentregistry-system
VERSION="${AR_ENT_VERSION:-2026.6.1}"
CHART="${AR_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"

ENVF="$LAB_ROOT/deploy/.env.oidc"
[[ -f "$ENVF" ]] || die "no $ENVF — run 30-keycloak.sh first"
# shellcheck disable=SC1090
source "$ENVF"
: "${OIDC_ISSUER:?}"
[[ -n "${AR_BACKEND_SECRET_ENC:-}" ]]     && AR_BACKEND_SECRET="$(kms_decrypt "$AR_BACKEND_SECRET_ENC")"
[[ -n "${KAGENT_BACKEND_SECRET_ENC:-}" ]] && KAGENT_BACKEND_SECRET="$(kms_decrypt "$KAGENT_BACKEND_SECRET_ENC")"
: "${AR_BACKEND_SECRET:?}" "${KAGENT_BACKEND_SECRET:?}"

step "namespace"
kc create ns "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── database: Cloud SQL, never the bundled Postgres ─────────────────────────
# Same two reasons as kagent, and the second is fatal on GCD: the bundled
# Postgres PVC default is below the 4 GB minimum that hyperdisk-balanced (the
# only disk type here, and the default StorageClass) enforces, so it never
# starts. Cloud SQL is also simply what a regulated customer would ship.
DB_ARGS=()
PSC_IP="${SQL_PSC_ENDPOINT_IP:-$(tofu_out sql_psc_endpoint_ip)}"
DB_URL="${AR_DB_URL:-}"
if [[ -z "$DB_URL" ]]; then
  DB_URL="$(cd "$TOFU_DIR" && tofu output -json sql_connection_urls 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agentregistry",""))' 2>/dev/null || true)"
fi

if [[ -n "$DB_URL" && -n "$PSC_IP" ]]; then
  step "Cloud SQL over Private Service Connect at ${PSC_IP}"
  # The chart takes the WHOLE connection string from a Secret via
  # database.postgres.external.secretRef, not host/port/user/password parts.
  # Default key name is AGENT_REGISTRY_DATABASE_URL. Using the secretRef form
  # keeps the password out of the Helm release values entirely.
  kc -n "$NS" create secret generic agentregistry-db \
    --from-literal=AGENT_REGISTRY_DATABASE_URL="$DB_URL" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  DB_ARGS=(
    --set database.postgres.type=external
    --set database.postgres.external.secretRef.name=agentregistry-db
    --set database.postgres.external.secretRef.key=AGENT_REGISTRY_DATABASE_URL
  )
  ok "external Postgres via secretRef, PSC endpoint ${PSC_IP}"
else
  warn "no Cloud SQL URL/endpoint in tofu output — falling back to bundled Postgres."
  warn "This chart defaults to 5Gi, which does clear the 4 GB hyperdisk-balanced"
  warn "floor (unlike kagent's 500Mi), so it should start — but it is still"
  warn "labelled dev/eval only by the chart itself."
  DB_ARGS=(--set database.postgres.type=bundled)
fi

step "agentregistry-enterprise $VERSION"
helm --kube-context "$(kube_context)" upgrade --install agentregistry "$CHART" \
  -n "$NS" --version "$VERSION" \
  --set oidc.issuer="$OIDC_ISSUER" \
  --set oidc.clientId=ar-backend \
  --set oidc.clientSecret="$AR_BACKEND_SECRET" \
  --set oidc.publicClientId=ar-ui \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole=admins \
  --set kagent.outboundAuth.oidc.clientId=kagent-backend \
  --set kagent.outboundAuth.oidc.clientSecret="$KAGENT_BACKEND_SECRET" \
  "${DB_ARGS[@]}" \
  >/dev/null
ok "chart applied"

step "waiting for the registry server"
kc -n "$NS" rollout status deploy/agentregistry-enterprise-server --timeout=300s || {
  warn "server not ready. Two usual causes here:"
  warn "  1. OIDC discovery — check the issuer resolves in-cluster"
  warn "  2. Cloud SQL connectivity — PSC endpoint, firewall, or the password"
  warn "  kubectl --context $(kube_context) -n $NS logs deploy/agentregistry-enterprise-server | tail -40"
  die "agentregistry server did not become ready"
}
ok "AgentRegistry ready on :12121 (ClusterIP; 80-ingress.sh exposes it)"

cat >&2 <<EOF

  Configuration note worth keeping: kagent.outboundAuth points at the
  kagent-backend client on purpose. When the registry later deploys an agent to
  the kagent runtime it mints a client-credentials token to call the kagent
  controller, and that token needs aud: kagent-backend. Point it anywhere else
  and the cross-product call fails authorization with a confusing error.

  Remember agentregistry has NO CRDs. Its ar.dev/v1alpha1 resources
  (Agent MCPServer Model Prompt Skill) are served over its own REST API and
  stored in Postgres, applied with arctl — not kubectl.

  Next: ./scripts/70-agentgateway.sh
EOF
