#!/usr/bin/env bash
# 70-agentgateway.sh — Solo Enterprise for agentgateway.
#
# THE key component on GCD. With no service mesh, no GKE network policies, no
# load-balancer mTLS or authorization policies, no Cloud NGFW Enterprise and no
# Cloud Armor Enterprise, agentgateway is the only L7 policy and audit point
# available anywhere in this universe. That is not positioning, it is the
# catalogue.
#
# Installed on the STANDALONE controller path — the enterprise-agentgateway
# GatewayClass. The waypoint GatewayClass is deliberately unused: a waypoint
# only intercepts traffic if ztunnel redirects it, and ambient cannot run on
# Autopilot. So no AgentgatewayParameters with CLUSTER_ID/NETWORK here, and no
# ambient namespace labels. Mixing the two modes fails silently.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl helm
load_env
assert_universe

NS=agentgateway-system
VERSION="${AGW_ENT_VERSION:-v2026.8.2}"
CHART_BASE="${AGW_CHART_BASE:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
GW_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"

: "${AGENTGATEWAY_LICENSE_KEY:?AGENTGATEWAY_LICENSE_KEY not set — check .env.local or ~/code/solo/secrets/secrets-envs.sh}"

# ── Gateway API: STANDARD channel only ───────────────────────────────────────
# The kind lab layers the EXPERIMENTAL channel on top, and has to delete a
# safe-upgrades ValidatingAdmissionPolicy to do it. That is only needed for
# ambient waypoints, which cannot exist here. So: standard channel, no policy
# deletion, no retry loop. One of the few places GCD makes life simpler.
step "Gateway API standard CRDs $GW_API_VERSION"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API installed (standard channel — experimental is not needed without waypoints)"

step "namespace"
kc create ns "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

step "enterprise-agentgateway-crds $VERSION"
helm --kube-context "$(kube_context)" upgrade --install enterprise-agentgateway-crds \
  "${CHART_BASE}/enterprise-agentgateway-crds" \
  -n "$NS" --version "$VERSION" --wait --timeout 5m >/dev/null
ok "CRDs installed"

step "enterprise-agentgateway $VERSION"
helm --kube-context "$(kube_context)" upgrade --install enterprise-agentgateway \
  "${CHART_BASE}/enterprise-agentgateway" \
  -n "$NS" --version "$VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 10m >/dev/null
ok "controller installed"

step "GatewayClasses"
kc get gatewayclass -o wide >&2

WAYPOINT="$(kc get gatewayclass enterprise-agentgateway-waypoint -o name 2>/dev/null || true)"
if [[ -n "$WAYPOINT" ]]; then
  warn "the waypoint GatewayClass is registered but UNUSABLE on GCD."
  warn "A waypoint is a normal Deployment, so it will schedule — but nothing"
  warn "redirects traffic to it without ztunnel, and ambient cannot run on"
  warn "Autopilot. Do not label MCPServers kagent.solo.io/waypoint=true here:"
  warn "the resources apply, the policy reports Accepted, and nothing is enforced."
  warn "Use 95-authz-on.sh instead, which enforces at the standalone gateway."
fi

cat >&2 <<EOF

  agentgateway is up on the standalone path.

  API-group trap, because mixing them fails silently:
    OSS        agentgateway.dev/v1alpha1
               AgentgatewayBackend AgentgatewayPolicy AgentgatewayParameters
    Enterprise enterpriseagentgateway.solo.io
               EnterpriseAgentgatewayPolicy EnterpriseAgentgatewayBackend
               EnterpriseAgentgatewayParameters EnterpriseAgentgatewayBudget
               EnterpriseAgentgatewayExternalSecret
    referenced AuthConfig (extauth.solo.io) RateLimitConfig (ratelimit.solo.io)
               WAFPolicy (waf.solo.io)

  And remember agentgateway is a RUST data plane with a Go controller, not
  Envoy. It borrows the xDS transport and serves its own resource types.

  Next: ./scripts/80-ingress.sh
EOF
