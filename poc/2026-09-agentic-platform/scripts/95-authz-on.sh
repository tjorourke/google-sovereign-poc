#!/usr/bin/env bash
# 95-authz-on.sh — MCP tool-level authorization, enforced at the STANDALONE
# agentgateway. This is the GCD substitute for the kind lab's waypoint demo.
#
# What the kind lab does, and why it cannot work here:
#   a kagent AccessPolicy is inert on its own. The kmcp translator reacts to
#   the label kagent.solo.io/waypoint=true by provisioning a waypoint Gateway,
#   HTTPRoute and AgentgatewayBackend in front of the MCP server, and
#   compiling the AccessPolicy into an EnterpriseAgentgatewayPolicy. But a
#   waypoint only INTERCEPTS traffic because ztunnel redirects it, and ambient
#   cannot run on GKE Autopilot — istio-cni needs hostNetwork + SYS_ADMIN,
#   ztunnel needs SYS_ADMIN + NET_ADMIN + runAsUser 0, Autopilot rejects both,
#   and GCD does not support the WorkloadAllowlist mechanism that would be the
#   only way to grant them. Cloud Service Mesh is unavailable too.
#
#   The trap: if you label the MCPServer here anyway, the waypoint Deployment
#   schedules, the policy reports Accepted, and NOTHING IS ENFORCED. It fails
#   silently, which is the worst possible failure mode for a security control.
#
# What we do instead: attach an AgentgatewayPolicy to the AgentgatewayBackend.
# The gateway evaluates each rule with the request's MCP context, including the
# tool name. Tools matching no expression are filtered out of tools/list and
# short-circuited on tools/call with JSON-RPC -32602 "Unknown tool".
#
# Same enforcement, same audit trail. What we lose is transparency: the agent
# has to be pointed at the gateway rather than the gateway intercepting
# whatever the agent dials. With kagent that is one field on a RemoteMCPServer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl
load_env
assert_universe

MCP_NS="${MCP_NS:-mcp}"
AGW_NS=agentgateway-system
GW=agentgateway-proxy
SERVER="${MCP_SERVER:-everything-server}"
ALLOW_TOOL="${ALLOW_TOOL:-sum}"
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"

kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1 \
  || die "agentgateway not installed — run 70-agentgateway.sh"
kc -n "$MCP_NS" get agentgatewaybackend "${SERVER}-mcp" >/dev/null 2>&1 \
  || die "no AgentgatewayBackend ${SERVER}-mcp — run 90-mcp-agent.sh"

step "applying MCP tool authorization: ALLOW only '$ALLOW_TOOL'"
# matchExpressions are OR-ed. A tool is visible iff at least one expression is
# true for the caller. Everything unmatched disappears.
#
# The jwt.* fields come from the Keycloak realm: sub, and Groups with a capital
# G (the group-membership mapper emits it that way and every role-mapper CEL in
# the platform reads claims.Groups — keep them aligned).
kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-tool-authz
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: ${SERVER}-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            # admins see and call everything
            - 'jwt.Groups.exists(g, g == "admins")'
            # everyone else gets exactly one tool. 'printenv' is deliberately
            # excluded — it is the one that leaks the pod environment.
            - 'mcp.tool.name == "${ALLOW_TOOL}"'
YAML
ok "AgentgatewayPolicy/mcp-tool-authz applied"

step "policy acceptance"
for i in $(seq 1 20); do
  ACC="$(kc -n "$MCP_NS" get agentgatewaypolicy mcp-tool-authz \
    -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  [[ "$ACC" == "True" ]] && break
  sleep 3
done
if [[ "${ACC:-}" == "True" ]]; then
  ok "policy Accepted by the gateway"
else
  warn "policy not reporting Accepted (got: ${ACC:-<none>}). Check:"
  warn "  kubectl --context $(kube_context) -n $MCP_NS get agentgatewaypolicy mcp-tool-authz -o yaml"
fi

# ── prove it ─────────────────────────────────────────────────────────────────
# A full MCP handshake, not a bare tools/list. Two things caught us out:
#   * the HTTPRoute matches on hostname, so the Host header is required or the
#     gateway correctly answers "route not found";
#   * MCP is session-based, so `initialize` must come first and its
#     Mcp-Session-Id header must be echoed on every later call, otherwise the
#     server answers "session header is required for non-initialize requests".
GW_SVC="$(kc -n "$AGW_NS" get svc -l "gateway.networking.k8s.io/gateway-name=${GW}" -o jsonpath='{.items[0].metadata.name}')"
step "MCP handshake through the gateway, then list and call"
kc -n "$MCP_NS" delete pod mcp-authz-probe --ignore-not-found --wait=false >/dev/null 2>&1
sleep 3
kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: mcp-authz-probe
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
          U="http://${GW_SVC}.${AGW_NS}.svc.cluster.local:80/mcp"
          H="Host: mcp.${BASE_DOMAIN}"
          CT='Content-Type: application/json'
          AC='Accept: application/json, text/event-stream'
          SID=\$(curl -sS -m 20 -D - -o /tmp/i -X POST "\$U" -H "\$H" -H "\$CT" -H "\$AC" \\
            -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gcd-probe","version":"1"}}}' \\
            | tr -d '\\r' | awk -F': ' '/^[Mm]cp-[Ss]ession-[Ii]d/{print \$2}')
          [ -z "\$SID" ] && { echo "NO_SESSION"; head -c 300 /tmp/i; exit 1; }
          curl -sS -m 20 -o /dev/null -X POST "\$U" -H "\$H" -H "\$CT" -H "\$AC" -H "Mcp-Session-Id: \$SID" \\
            -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
          echo "=== tools/list"
          curl -sS -m 20 -X POST "\$U" -H "\$H" -H "\$CT" -H "\$AC" -H "Mcp-Session-Id: \$SID" \\
            -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | tr -d '\\r'; echo
          echo "=== call ${ALLOW_TOOL}"
          curl -sS -m 20 -X POST "\$U" -H "\$H" -H "\$CT" -H "\$AC" -H "Mcp-Session-Id: \$SID" \\
            -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"${ALLOW_TOOL}","arguments":{"a":2,"b":3}}}'; echo
          echo "=== call printenv"
          curl -sS -m 20 -X POST "\$U" -H "\$H" -H "\$CT" -H "\$AC" -H "Mcp-Session-Id: \$SID" \\
            -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"printenv","arguments":{}}}'; echo
YAML
for i in $(seq 1 24); do
  P="$(kc -n "$MCP_NS" get pod mcp-authz-probe -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "$P" == "Succeeded" || "$P" == "Failed" ]] && break
  sleep 10
done
LOGS="$(kc -n "$MCP_NS" logs mcp-authz-probe 2>/dev/null || true)"
printf '%s\n' "$LOGS" >&2

EV="$REPO_ROOT/feedback/google/evidence/berlin-mcp-tool-authz-$(date -u +%Y-%m-%d).txt"
mkdir -p "$(dirname "$EV")"
{
  printf '# MCP tool-level authorization at a standalone agentgateway on GKE Autopilot (GCD)\n'
  printf '# %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# No mesh in this cluster: no ambient, no ztunnel, no waypoint, no NetworkPolicy.\n\n'
  printf '%s\n' "$LOGS"
} >"$EV"
ok "evidence written to $EV"

# Judge only the RESPONSES. An earlier version grepped the whole transcript for
# "32602", which also matches the request body -- a false pass on a security
# control, which is the worst possible bug in a check like this.
grep -q 'route not found' <<<"$LOGS" && die "gateway answered 'route not found' — Host header or HTTPRoute hostname is wrong"
grep -q 'NO_SESSION' <<<"$LOGS" && die "MCP initialize did not return a session id"

LIST="$(sed -n '/=== tools\/list/,/=== call/p' <<<"$LOGS")"
DENY="$(sed -n '/=== call printenv/,$p' <<<"$LOGS" | grep -v '=== call printenv')"

PASS=1
grep -q "\"${ALLOW_TOOL}\"" <<<"$LIST"      || { warn "'${ALLOW_TOOL}' missing from tools/list"; PASS=0; }
grep -q '"printenv"' <<<"$LIST"               && { warn "'printenv' is still listed — not filtered"; PASS=0; }
grep -qE '"code":-32602|Unknown tool' <<<"$DENY" || { warn "denied tool did not error"; PASS=0; }

if (( PASS )); then
  ok "only '${ALLOW_TOOL}' is listed; 'printenv' is filtered and denied on call"
else
  die "tool-level authorization is NOT enforced — see the transcript above"
fi

cat >&2 <<EOF

  This is the GCD story in one command. There is no service mesh in this
  cluster, no ztunnel, no waypoint, no GKE network policy, no load-balancer
  mTLS and no Cloud NGFW Enterprise — and an agent still cannot call a tool it
  is not authorized for, with the decision logged.

  What we lose versus ambient: transparent interception and workload mTLS. Say
  both plainly; do not let a slide imply otherwise.

  Revert: ./scripts/95-authz-off.sh
EOF
