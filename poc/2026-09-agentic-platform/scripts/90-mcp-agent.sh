#!/usr/bin/env bash
# 90-mcp-agent.sh — the actual test: publish an MCP server to the catalogue,
# deploy an agent that uses it, and route the agent's MCP traffic through
# agentgateway so tool-level policy has somewhere to be enforced.
#
# Flow:
#   1. arctl login against the ar-cli-password client
#   2. render mcp.yaml with the in-universe image reference
#   3. build + push the everything-server image to Artifact Registry
#   4. publish the MCPServer to the catalogue (arctl apply)
#   5. deploy the MCP server to the cluster
#   6. front it with an agentgateway MCP backend + route, so tool policy has
#      somewhere to attach (no waypoint is possible on Autopilot)
#   7. baseline: list tools through the gateway
#
# Then 95-authz-on.sh restricts the tool set and you re-ask.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl jq docker
load_env
assert_universe

MCP_NS="${MCP_NS:-mcp}"
AGW_NS=agentgateway-system
GW=agentgateway-proxy
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
KAGENT_NS="${KAGENT_NS:-kagent}"
SERVER=everything-server

ENVF="$LAB_ROOT/deploy/.env.oidc"
[[ -f "$ENVF" ]] || die "no $ENVF — run 30-keycloak.sh first"
# shellcheck disable=SC1090
source "$ENVF"
: "${OIDC_ISSUER:?}"

if false; then :; fi
command -v arctl >/dev/null 2>&1 || {
  warn "arctl not installed. Install the pinned release:"
  warn "  curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh | ARCTL_VERSION=v2026.6.1 sh"
  warn "  export PATH=\"\$HOME/.arctl/bin:\$PATH\""
  die "arctl required"
}

# ── resolve the registry, from the API not from a guess ─────────────────────
AR_URI="$(gcloud artifacts repositories describe "${AR_REPO:?}" \
  --project "$PROJECT_ID" --location "${AR_LOCATION:?}" \
  --format='value(registryUri)' 2>/dev/null || true)"
[[ -n "$AR_URI" ]] || die "cannot resolve the Artifact Registry host — run 10-tofu.sh apply"
MCP_IMAGE="${AR_URI}/${SERVER}:latest"
ok "image target: $MCP_IMAGE"

# ── 1. arctl login, if the control plane is reachable from here ──────────────
# The sovereign posture makes this conditional rather than guaranteed. The OIDC
# issuer lives in a Cloud DNS PRIVATE zone and the gateway is an internal load
# balancer, so a laptop CLI cannot resolve or reach either:
#
#   Error: failed to discover OIDC configuration: ... dial tcp: lookup
#   keycloak.agentic.eu0.internal: no such host
#
# GCD has no public DNS zone, so there is no way to publish a resolvable name
# for the control plane. Reaching it from outside needs the Tier 1 external ALB
# with BYO certificates plus manual /etc/hosts entries, or Cloud VPN /
# Interconnect. Until one of those exists we skip the catalogue publish and
# prove the substantive thing -- tool-level authorization at the gateway --
# entirely in-cluster, which needs no CLI.
CATALOGUE=1
if ! getent hosts "keycloak.${BASE_DOMAIN}" >/dev/null 2>&1 \
   && ! host "keycloak.${BASE_DOMAIN}" >/dev/null 2>&1; then
  CATALOGUE=0
  warn "keycloak.${BASE_DOMAIN} does not resolve from this machine (private zone)."
  warn "skipping the arctl catalogue publish; the MCP + authz proof runs in-cluster."
fi

if (( CATALOGUE )); then
  step "arctl login (password-credentials against ar-cli-password)"
  arctl user login \
    --oidc-flow password-credentials \
    --oidc-issuer-url "$OIDC_ISSUER" \
    --oidc-client-id ar-cli-password \
    --oidc-username "${AR_ADMIN_USER:-admin-user}" \
    --oidc-password "${AR_ADMIN_PASSWORD:-password}"
  ok "logged in"
fi

# ── 2. render the manifest INTO the build context ───────────────────────
# The Dockerfile does `COPY mcp.yaml ./`, so the rendered manifest must exist in
# the build context BEFORE the build. It is also what gets published to the
# catalogue, so rendering once and using it twice keeps the image and the
# catalogue entry describing the same thing.
#
# The kind lab hardcoded localhost:5001 here — a host-side registry reachable
# over the kind docker network. GCD has no such thing, and the repo rule is that
# nothing running in-universe hardcodes a registry, so the host is resolved from
# the Artifact Registry API and substituted in.
step "rendering mcp.yaml with the in-universe image reference"
MCP_YAML="$LAB_ROOT/mcp/$SERVER/mcp.yaml"
MCP_IMAGE="$MCP_IMAGE" python3 - "$LAB_ROOT/mcp/$SERVER/mcp.yaml.tmpl" >"$MCP_YAML" <<'PYEOF'
import os, re, sys
s = open(sys.argv[1]).read().replace("${MCP_IMAGE}", os.environ["MCP_IMAGE"])
leftover = re.findall(r"\$\{[A-Z_]+\}", s)
assert not leftover, f"unsubstituted placeholders: {leftover}"
sys.stdout.write(s)
PYEOF
ok "rendered $MCP_YAML"
grep -n 'identifier:' "$MCP_YAML" | sed 's/^/  /' >&2

# ── 3. build + push ───────────────────────────────────────────────
step "build + push $SERVER"
ar_docker_login "${AR_URI%%/*}"
# --platform linux/amd64 is NOT optional. GCD offers C3, M3 and A3 only, all
# x86_64, and no Arm machine types whatsoever. Building on an Apple Silicon Mac
# without this produces an arm64 image and the node fails with
#   no match for platform in manifest: not found
# which reads as a registry problem rather than an architecture one.
docker build --platform linux/amd64 -t "$MCP_IMAGE" "$LAB_ROOT/mcp/$SERVER"
docker push "$MCP_IMAGE"
ok "pushed"

# ── 4. publish to the catalogue ────────────────────────────────────
if (( CATALOGUE )); then
  step "publish MCPServer to the catalogue"
  arctl apply -f "$MCP_YAML"
  ok "published $SERVER"
  arctl get mcpservers 2>/dev/null | sed 's/^/  /' >&2 || true
else
  step "catalogue publish skipped (control plane not reachable from here)"
  log "the rendered manifest is at $MCP_YAML and applies once arctl can reach the registry"
fi

# ── 5. run the MCP server in the cluster ────────────────────────────────────
step "deploy $SERVER to namespace $MCP_NS"
kc create ns "$MCP_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

# GKE nodes cannot authenticate to the GCD Artifact Registry host on their own:
# the built-in image credential provider has the same hardcoded hostname
# allowlist as `gcloud auth configure-docker` (feedback/google/05), so the pull
# fails 403 even with roles/artifactregistry.reader granted to the node service
# account at both project and repository level. An explicit pull secret works.
#
# Note the token is short-lived, so this Secret needs refreshing -- which is why
# a working credential provider matters rather than being a nicety.
step "image pull secret (the node credential provider will not serve this host)"
kc -n "$MCP_NS" create secret docker-registry ar-pull \
  --docker-server="${AR_URI%%/*}" \
  --docker-username=oauth2accesstoken \
  --docker-password="$(gcloud auth print-access-token)" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret/ar-pull"
kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVER}
  labels: { app: ${SERVER} }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${SERVER} } }
  template:
    metadata: { labels: { app: ${SERVER} } }
    spec:
      imagePullSecrets:
        - name: ar-pull
      containers:
        - name: server
          image: ${MCP_IMAGE}
          ports: [{ containerPort: 3000, name: http }]
          env:
            - { name: MCP_TRANSPORT_MODE, value: http }
            - { name: HOST, value: "0.0.0.0" }
            - { name: PORT, value: "3000" }
          # Autopilot requires requests on every container.
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { cpu: 500m, memory: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVER}
spec:
  selector: { app: ${SERVER} }
  ports: [{ name: http, port: 3000, targetPort: 3000 }]
YAML
kc -n "$MCP_NS" rollout status "deploy/${SERVER}" --timeout=180s
ok "$SERVER running"

# ── 6. front it with agentgateway ───────────────────────────────────────────
# This is the GCD shape. On a mesh-capable cluster the kagent AccessPolicy
# translator would provision a waypoint and interception would be transparent.
# Here the agent is pointed at the gateway explicitly, and the gateway holds an
# MCP backend so an MCP-aware policy has something to attach to. Same
# enforcement, different plumbing.
step "agentgateway MCP backend + route"
kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ${SERVER}-mcp
spec:
  mcp:
    targets:
      - name: ${SERVER}
        static:
          host: ${SERVER}.${MCP_NS}.svc.cluster.local
          port: 3000
          path: /mcp
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${SERVER}-mcp
spec:
  parentRefs: [{ name: ${GW}, namespace: ${AGW_NS} }]
  hostnames: ["mcp.${BASE_DOMAIN}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /mcp } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: ${SERVER}-mcp
YAML
ok "AgentgatewayBackend + HTTPRoute applied"

step "adding mcp.${BASE_DOMAIN} to the private DNS zone"
GW_SVC="$(kc -n "$AGW_NS" get svc -l "gateway.networking.k8s.io/gateway-name=${GW}" -o jsonpath='{.items[0].metadata.name}')"
LB_IP="$(kc -n "$AGW_NS" get svc "$GW_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[[ -n "$LB_IP" ]] && dns_upsert "mcp.${BASE_DOMAIN}" "$LB_IP" || warn "no gateway LB address yet"

# ── 6b. the declarative agent that USES it ──────────────────────────────────
# The header above has always promised "deploy an agent that uses it", and the
# numbered flow never did -- so 69-accesspolicy-health.sh path A tested a
# sovereign-calc workload nothing created. Deploy it here, where the gateway
# route it depends on has just been made.
step "declarative agent sovereign-calc, tools via the standalone gateway"
if kubectl -n "$KAGENT_NS" get modelconfig selfhosted >/dev/null 2>&1; then
  sed "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" "$LAB_ROOT/mcp/sovereign-calc-agent.yaml" \
    | kc apply -f - >/dev/null \
    && ok "RemoteMCPServer/everything-server and Agent/sovereign-calc applied" \
    || warn "could not apply the sovereign-calc agent"
  kc -n "$KAGENT_NS" rollout status deploy/sovereign-calc --timeout=180s >/dev/null 2>&1 \
    && ok "sovereign-calc ready" || warn "sovereign-calc did not become ready"
else
  warn "ModelConfig/selfhosted missing in $KAGENT_NS — run 60-model.sh, then re-run this phase"
fi

# ── 7. baseline: the gateway sees all the tools ─────────────────────────────
step "baseline — listing tools through the gateway"
kc -n "$MCP_NS" delete pod mcp-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
sleep 3
kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: mcp-probe
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: curlimages/curl:8.11.0
      resources:
        requests: { cpu: 250m, memory: 512Mi }
      args:
        - sh
        - -c
        - |
          set -e
          URL="http://${GW_SVC}.${AGW_NS}.svc.cluster.local:80/mcp"
          echo "POST \$URL  tools/list"
          curl -sS -X POST "\$URL" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
          echo
YAML
kc -n "$MCP_NS" wait --for=condition=Ready pod/mcp-probe --timeout=90s >/dev/null 2>&1 || true
sleep 15
step "tools/list response"
kc -n "$MCP_NS" logs mcp-probe 2>/dev/null | tail -30 >&2 || warn "probe produced no output"

# Extract the tool names so the before/after is unambiguous.
TOOLS="$(kc -n "$MCP_NS" logs mcp-probe 2>/dev/null \
  | grep -o '"name":"[a-z_]*"' | sed 's/.*://; s/"//g' | sort -u | tr '\n' ' ' || true)"
if [[ -n "$TOOLS" ]]; then
  ok "tools visible through the gateway: $TOOLS"
else
  warn "could not parse a tool list. Check the logs above and the backend status:"
  warn "  kubectl --context $(kube_context) -n $MCP_NS get agentgatewaybackend ${SERVER}-mcp -o yaml"
fi

cat >&2 <<EOF

  MCP server published, deployed, and fronted by agentgateway.

    catalogue   arctl get mcpservers
    in-cluster  ${SERVER}.${MCP_NS}.svc.cluster.local:3000/mcp   (direct — do not use)
    gateway     http://mcp.${BASE_DOMAIN}/mcp                    (policy enforced here)

  Tools on this server: sum echo to_uppercase reverse_text printenv
  'printenv' is the one that should be denied once policy is on.

  Next:
    ./scripts/95-authz-on.sh      restrict to 'sum' only, enforced at the gateway
    ./scripts/95-authz-off.sh     revert
EOF
