#!/usr/bin/env bash
# 40-kagent.sh — Solo Enterprise for kagent: the agent runtime.
#
# Two charts, CRDs then controller. The controller runs an OIDC access-token
# interceptor and refuses to start without a discoverable issuer, so Keycloak
# and its private DNS record must already be up (30-keycloak.sh).
#
# oidc.skipOBO=false turns on on-behalf-of token exchange, which needs an RSA
# signing key in a Secret that MUST be named `jwt` in the kagent namespace.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl helm openssl jq
load_env
assert_universe

NS=kagent
VERSION="${KAGENT_ENT_VERSION:-0.4.3}"
CHART_BASE="${SOLO_CHART_BASE:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts}"
OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://solo-enterprise-telemetry-collector.solo-enterprise.svc.cluster.local:4317}"

# ── OIDC values from 30-keycloak.sh, decrypted from Cloud KMS ────────────────
ENVF="$LAB_ROOT/deploy/.env.oidc"
[[ -f "$ENVF" ]] || die "no $ENVF — run 30-keycloak.sh first"
# shellcheck disable=SC1090
source "$ENVF"
: "${OIDC_ISSUER:?}"
if [[ -n "${KAGENT_BACKEND_SECRET_ENC:-}" ]]; then
  KAGENT_BACKEND_SECRET="$(kms_decrypt "$KAGENT_BACKEND_SECRET_ENC")"
fi
: "${KAGENT_BACKEND_SECRET:?no kagent-backend client secret}"

: "${SOLO_LICENSE_KEY:?SOLO_LICENSE_KEY not set — source ~/code/solo/secrets/secrets-envs.sh}"

step "namespace"
kc create ns "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# ── OBO signing key. The Secret MUST be called `jwt`. ───────────────────────
step "OBO RSA signing key (Secret must be named 'jwt')"
if kc -n "$NS" get secret jwt >/dev/null 2>&1; then
  ok "secret/jwt already present"
else
  TMPK="$(mktemp)"; trap 'rm -f "$TMPK"' EXIT
  openssl genpkey -algorithm RSA -out "$TMPK" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
  kc -n "$NS" create secret generic jwt --from-file=jwt="$TMPK" >/dev/null
  ok "secret/jwt created"
fi

step "kagent-backend client secret"
kc -n "$NS" create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="$KAGENT_BACKEND_SECRET" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret/kagent-enterprise-oidc-secret"

# ── database: Cloud SQL, never the bundled Postgres ─────────────────────────
# Two independent reasons, and the second one is fatal rather than merely
# advisable:
#
#  1. The chart's own values comment says the bundled instance is "for
#     development and evaluation only. Not suitable for production."
#  2. It does not start on GCD at all. Its PVC default is `storage: 500Mi`, and
#     hyperdisk-balanced -- the ONLY disk type in GCD and the default
#     StorageClass -- has a 4 GB minimum:
#       CreateVolume failed to create single zonal disk ...: googleapi:
#       Error 400: Disk size cannot be smaller than 4 GB for disk type
#       hyperdisk-balanced
#     The PVC sits Pending, and the controller CrashLoopBackOffs on
#     "database migration failed ... connection refused" -- which points at the
#     database rather than at the disk, so the real cause is easy to miss.
step "wiring kagent at Cloud SQL"
DB_URL="${KAGENT_DB_URL:-}"
if [[ -z "$DB_URL" ]]; then
  DB_URL="$(cd "$TOFU_DIR" && tofu output -json sql_connection_urls 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kagent",""))' 2>/dev/null || true)"
fi
if [[ -n "$DB_URL" ]]; then
  # Hold the URL in a Secret rather than passing it on the Helm command line,
  # so the password does not land in the release values.
  kc -n "$NS" create secret generic kagent-db \
    --from-literal=url="$DB_URL" --dry-run=client -o yaml | kc apply -f - >/dev/null
  DB_ARGS=(
    --set database.postgres.bundled.enabled=false
    --set database.postgres.urlFile=/etc/kagent-db/url
    # The keys are controller.volumes / controller.volumeMounts. NOT
    # extraVolumes/extraVolumeMounts -- those do not exist in this chart, and
    # setting them is silently ignored, so `urlFile` points at a path that was
    # never mounted and the controller fails with
    #   "reading URL file: open /etc/kagent-db/url: no such file or directory"
    --set-json 'controller.volumes=[{"name":"kagent-db","secret":{"secretName":"kagent-db"}}]'
    --set-json 'controller.volumeMounts=[{"name":"kagent-db","mountPath":"/etc/kagent-db","readOnly":true}]'
  )
  ok "Cloud SQL at $(sed -E 's|://[^@]*@|://***@|' <<<"$DB_URL")"
else
  warn "no Cloud SQL URL in tofu output — falling back to the bundled Postgres."
  warn "On GCD that WILL fail: 500Mi PVC vs the 4 GB hyperdisk-balanced minimum."
  warn "Raise it with --set database.postgres.bundled.storage=4Gi if you must."
  DB_ARGS=(--set database.postgres.bundled.storage=4Gi)
fi

step "kagent-enterprise-crds $VERSION"
helm --kube-context "$(kube_context)" upgrade --install kagent-crds \
  "${CHART_BASE}/kagent-enterprise-crds" \
  -n "$NS" --version "$VERSION" --wait --timeout 5m >/dev/null
ok "CRDs installed"

# ── model provider ───────────────────────────────────────────────────────────
# GCD has NO aiplatform, so there is no managed model endpoint. The sovereign
# answer is a self-hosted model (60-model.sh), which agentgateway fronts. Set
# MODEL_PROVIDER=selfhosted to wire kagent at the gateway instead of a SaaS
# provider. anthropic remains available only if probe 0.2 said egress works,
# and it is the wrong demo for this audience.
# AccessPolicy (policy.kagent-enterprise.solo.io) only compiles into enforcement
# objects when this is on, and it is what stamps kagent.solo.io/waypoint onto
# Agents. The chart default is false, which is right for a cluster with no mesh.
# Turn it on once Istio ambient is installed (64-istio-ambient.sh). Leaving it on
# without a mesh is harmless: AccessPolicy objects simply report Failed.
ISTIO_AUTHZ_TRANSLATION="${ISTIO_AUTHZ_TRANSLATION:-true}"

MODEL_PROVIDER="${MODEL_PROVIDER:-selfhosted}"
PROVIDER_ARGS=()
case "$MODEL_PROVIDER" in
  selfhosted)
    MODEL_BASE_URL="${MODEL_BASE_URL:-http://agentgateway.agentgateway-system.svc.cluster.local:80/v1}"
    PROVIDER_ARGS=(
      --set providers.default=openAI
      --set providers.openAI.baseUrl="$MODEL_BASE_URL"
      --set providers.openAI.model="${MODEL_NAME:-gemma-3-27b-it}"
      --set-string providers.openAI.apiKey="not-used-selfhosted"
    )
    log "model: self-hosted via agentgateway at $MODEL_BASE_URL"
    log "the OpenAI-compatible surface is vLLM's; agentgateway is the policy point"
    ;;
  anthropic)
    : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"
    PROVIDER_ARGS=(
      --set providers.default=anthropic
      --set providers.anthropic.apiKey="$ANTHROPIC_API_KEY"
    )
    warn "using Anthropic over public egress — fine for a smoke test, wrong for a sovereign demo"
    ;;
  *) die "MODEL_PROVIDER must be selfhosted or anthropic" ;;
esac

step "kagent-enterprise $VERSION"
# No --wait: the controller does OIDC discovery at startup. With private DNS in
# place that should now succeed immediately, unlike the kind lab where a
# hostAlias had to be patched in first. Kept separate anyway so a discovery
# failure surfaces as a pod log rather than a helm timeout.
helm --kube-context "$(kube_context)" upgrade --install kagent \
  "${CHART_BASE}/kagent-enterprise" \
  -n "$NS" --version "$VERSION" \
  --set global.licensing.licenseKey="$SOLO_LICENSE_KEY" \
  "${PROVIDER_ARGS[@]}" \
  --set controller.istioAuthzTranslation.enabled="$ISTIO_AUTHZ_TRANSLATION" \
  --set oidc.issuer="$OIDC_ISSUER" \
  --set oidc.clientId=kagent-backend \
  --set oidc.secretRef=kagent-enterprise-oidc-secret \
  --set oidc.secretKey=clientSecret \
  --set oidc.skipOBO=false \
  --set-json 'controller.envFrom=[{"configMapRef":{"name":"kagent-enterprise-config"}}]' \
  "${DB_ARGS[@]}" \
  --set kagent-tools.enabled=true \
  --set ui.enabled=false \
  --set otel.tracing.enabled=true \
  --set otel.tracing.exporter.otlp.endpoint="$OTEL_ENDPOINT" \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  >/dev/null
ok "chart applied"

step "waiting for the controller"
if ! kc -n "$NS" rollout status deploy/kagent-controller --timeout=240s 2>/dev/null; then
  warn "controller not ready. The usual cause is OIDC discovery failing. Check:"
  warn "  kubectl --context $(kube_context) -n $NS logs deploy/kagent-controller | tail -40"
  warn "  and confirm the issuer resolves from inside the cluster:"
  warn "  kubectl --context $(kube_context) -n $NS run dns --rm -it --restart=Never \\"
  warn "    --image=gcr.io/google-containers/busybox:1.27.2 -- nslookup keycloak.${BASE_DOMAIN:-agentic.eu0.internal}"
  die "kagent controller did not become ready"
fi
ok "kagent controller ready"

step "CRDs registered"
kc get crd -o name | grep -E 'kagent|kmcp' | sed 's|customresourcedefinition.apiextensions.k8s.io/|  |' >&2 || true

cat >&2 <<EOF

  kagent is up. Note the CRD version spread — do NOT blanket-write v1alpha2:
    kagent.dev/v1alpha2  Agent ModelConfig AgentHarness ModelProviderConfig
                         RemoteMCPServer SandboxAgent
    kagent.dev/v1alpha1  Memory ToolServer  (Agent and ModelConfig also served here)
    kagent.dev/v1alpha1  MCPServer  (from KMCP — group is kagent.dev, NOT kmcp.io,
                                     the kagent repo's own docs are wrong on this)

  Next: ./scripts/45-telemetry.sh
EOF
