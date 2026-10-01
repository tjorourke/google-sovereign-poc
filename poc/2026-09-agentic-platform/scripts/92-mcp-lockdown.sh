#!/usr/bin/env bash
# 92-mcp-lockdown.sh — every MCP server locked down, reachable only through one
# shared agentgateway waypoint, and each agent allowed only its own tools.
#
# How it fits together:
#
#   agent pod (ambient ns) ──HBONE──▶ mcp-waypoint ──▶ MCP pod (ns mcp)
#        dials <svc>.mcp.svc.cluster.local:3000/mcp
#
#   1. The namespaces agents run in, and mcp, are ambient, so ztunnel gives every
#      pod a SPIFFE identity (namespace + ServiceAccount) and carries its traffic.
#   2. yaml/mcp-mesh/waypoint.yaml: one Gateway, mcp-waypoint, and an HTTPRoute
#      per MCP Service sending it to that server's AgentgatewayBackend. Each
#      Service is labelled istio.io/use-waypoint=mcp-waypoint, so ztunnel steers
#      every call to it through the waypoint. One waypoint for all servers.
#   3. One EnterpriseAgentgatewayPolicy per agent per backend, <agent>--<backend>,
#      rendered by mcp_policies.py from yaml/mcp-mesh/grants.json:
#        source.identity.namespace == NS && source.identity.serviceAccount == SA
#          && mcp.tool.name in [...]
#      agentgateway ORs every Allow policy attached to a backend, so adding an
#      agent adds a CRD and edits none. Default deny: mcp-catalog--tools-list is
#      attached to every backend, and a caller no policy names sees no tools and
#      gets "Unknown tool". No HTTP header is trusted; the identity is the
#      caller's mTLS certificate.
#      mcp_security.py adds Strict JWT authentication and requires its subject to
#      match that certificate identity; projected workload tokens rotate hourly.
#   4. yaml/mcp-mesh/catalog.yaml: mcp-catalog, the one identity allowed to LIST
#      tools everywhere (never call them), so the console can show an admin what
#      a server offers before approving it for an agent.
#   5. The edge routes (mcp.<domain>/mcp/*) are deleted: no path around the
#      waypoint. mcp_security.py then has ztunnel admit only the
#      waypoint's own identity at the MCP pods, so a pod-IP dial, or a caller
#      outside the mesh, is refused too. Service-selector backends preserve
#      workload mTLS on the waypoint-to-MCP hop; static DNS targets do not.
#
# This supersedes 95-authz-on.sh (one tool allowlist for every caller, at the edge).
#
# The demo console adds the agents an admin approves (the builder) on top of
# grants.json and rewrites the same policies. Re-running this script writes the
# fixed grants only and prunes only its own policies. Console approvals survive.
#
# The MCP servers themselves come from 90-mcp-agent.sh (everything-server) and the
# TrustUsBank deploys; a Service that is not there yet is skipped, and running
# this again after a deploy picks it up.
#
#   ./scripts/92-mcp-lockdown.sh            apply and verify
#   ./scripts/92-mcp-lockdown.sh --verify   verify only
#   GCD_KUBECONFIG=deploy/console.kubeconfig KUBE_CONTEXT=berlin-console ./scripts/92-mcp-lockdown.sh
#                                           run it with the console's identity, no gcloud login
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl python3
load_env

NS=mcp
MESH="$LAB_ROOT/yaml/mcp-mesh"
AGENT_NAMESPACES=(mcp agentregistry-system kagent agents)
export KUBE_CONTEXT="${KUBE_CONTEXT:-$(kube_context)}"
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

services() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["services"]))' "$MESH/grants.json"; }

apply() {
  step "ambient namespaces"
  for ns in "${AGENT_NAMESPACES[@]}"; do
    k get ns "$ns" >/dev/null 2>&1 || { warn "$ns missing, skipped"; continue; }
    k label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
    ok "$ns"
  done

  step "shared waypoint and mesh routes"
  k apply -f "$MESH/waypoint.yaml"
  k -n "$NS" rollout status deploy/mcp-waypoint --timeout=180s
  for svc in $(services); do
    if k -n "$NS" get svc "$svc" >/dev/null 2>&1; then
      k -n "$NS" label svc "$svc" istio.io/use-waypoint=mcp-waypoint --overwrite >/dev/null
      ok "$svc → mcp-waypoint"
    else
      warn "$svc not deployed yet, skipped"
    fi
  done

  step "mcp-catalog (list-only identity)"
  local img="${MCP_CATALOG_IMAGE:-$(k -n "$NS" get deploy everything-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)}"
  [[ -n "$img" ]] || die "no image for mcp-catalog: set MCP_CATALOG_IMAGE (anything with python3), or run 90-mcp-agent.sh"
  sed "s|__MCP_IMAGE__|$img|" "$MESH/catalog.yaml" | k apply -f -
  k -n "$NS" rollout status deploy/mcp-catalog --timeout=180s

  step "per-agent policies (default deny)"
  # Applies one policy per agent per backend and prunes any this side owns that
  # grants.json no longer names (the console's builder policies are left alone).
  python3 "$SCRIPT_DIR/mcp_policies.py" --apply
  # The old single allowlist from 95-authz-on.sh would sit alongside and confuse.
  k -n "$NS" delete agentgatewaypolicy mcp-tool-authz --ignore-not-found

  step "agent waypoints, rotating MCP workload tokens and in-mesh endpoints"
  python3 "$SCRIPT_DIR/mcp_security.py" agents
  for ns in agentregistry-system kagent agents; do
    k -n "$ns" rollout status deployment -l app.kubernetes.io/managed-by=kagent --timeout=300s
  done

  step "strict JWTs and no way round the waypoint"
  python3 "$SCRIPT_DIR/mcp_security.py" servers
  python3 "$SCRIPT_DIR/mcp_security.py" discovery
  for svc in $(services); do
    k -n "$NS" delete httproute "$svc-mcp" --ignore-not-found
  done
}

# tools/list as the catalog identity: the only caller every backend admits.
list_tools() {
  local svc="$1" path="$2"
  k -n "$NS" exec -i deploy/mcp-catalog -- python3 - "http://$svc.$NS.svc.cluster.local:3000$path" <<'PY'
import json, sys, urllib.request
from pathlib import Path
url = sys.argv[1]
H = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
def rpc(body, sid=None):
    h = dict(H, **({"mcp-session-id": sid} if sid else {}))
    h["Authorization"] = "Bearer " + Path("/var/run/secrets/mcp/token").read_text().strip()
    r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), h), timeout=10)
    raw = r.read().decode()
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:]
    return r.headers.get("mcp-session-id") or sid, (json.loads(raw) if raw.strip() else {})
sid, _ = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "mcp-catalog", "version": "1"}}})
rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
_, res = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
print(" ".join(t["name"] for t in res.get("result", {}).get("tools", [])))
PY
}

verify() {
  step "verify"
  local fail=0
  while read -r svc path; do
    k -n "$NS" get svc "$svc" >/dev/null 2>&1 || { warn "$svc missing"; fail=1; continue; }
    tools="$(list_tools "$svc" "$path" 2>/dev/null || true)"
    if [[ -n "$tools" ]]; then ok "$svc: catalog sees $tools"; else warn "$svc: catalog sees no tools"; fail=1; fi
  done < <(python3 - "$MESH/grants.json" <<'PY'
import json, sys
for name, s in json.load(open(sys.argv[1]))["services"].items():
    print(name, s["path"])
PY
  )
  local routes; routes="$(k -n "$NS" get httproute -o name)" || die "cannot list routes in $NS"
  if grep -q -- '-mcp$' <<<"$routes"; then
    warn "an edge MCP route is still there"; fail=1
  else
    ok "no edge MCP routes"
  fi
  local n; n="$(k -n "$NS" get enterpriseagentgatewaypolicy -l app.kubernetes.io/managed-by=mcp-lockdown -o name | wc -l | tr -d ' ')"
  ok "$n per-agent policies"
  return $fail
}

[[ "${1:-}" == "--verify" ]] || apply
verify
