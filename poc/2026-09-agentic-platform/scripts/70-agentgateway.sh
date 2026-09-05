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
# Standard channel is enough EVEN THOUGH this cluster now has waypoints: an
# Istio waypoint is an ordinary gateway.networking.k8s.io/v1 Gateway, which is
# in the standard channel. The old note here said experimental was unnecessary
# "without waypoints", which stopped being the reason on 2026-09-04 when
# ambient came up. Keep the channel, correct the reasoning.
ok "Gateway API installed (standard channel — waypoints use the standard v1 Gateway)"

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

# This block used to say the waypoint GatewayClass was "UNUSABLE on GCD" and
# that MCPServers must NOT be labelled kagent.solo.io/waypoint=true, because
# ambient could not run on Autopilot. That stopped being true on 2026-09-04:
# istio-cni and ztunnel are admitted through customer-owned WorkloadAllowlists,
# 66-istio-health.sh verifies L7 enforcement AT a waypoint, and
# 67-accesspolicy-setup.sh uses exactly that label to get AccessPolicy
# enforcing. Leaving the warning in place would have told an operator not to do
# the thing that now works.
#
# Decide from the cluster rather than from an assumption about the platform.
WAYPOINT="$(kc get gatewayclass enterprise-agentgateway-waypoint -o name 2>/dev/null || true)"
if [[ -n "$WAYPOINT" ]]; then
  if kc -n istio-system get ds ztunnel >/dev/null 2>&1; then
    ok "waypoint GatewayClass registered, and ztunnel is present to redirect to it"
    log "both paths are available here:"
    log "  standalone gateway  — 95-authz-on.sh, tool policy on the gateway"
    log "  waypoint            — 67-accesspolicy-setup.sh, AccessPolicy at the waypoint"
  else
    warn "the waypoint GatewayClass is registered but there is no ztunnel in"
    warn "istio-system, so nothing redirects traffic to a waypoint. A waypoint"
    warn "would schedule and enforce nothing: the resources apply and the policy"
    warn "reports Accepted. Install ambient first (62/63/64), or use"
    warn "95-authz-on.sh, which enforces at the standalone gateway."
  fi
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
