#!/usr/bin/env bash
# 95-authz-off.sh — remove the MCP tool authorization, back to all tools visible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require gcloud kubectl
load_env
assert_universe

MCP_NS="${MCP_NS:-mcp}"
step "removing AgentgatewayPolicy/mcp-tool-authz"
kc -n "$MCP_NS" delete agentgatewaypolicy mcp-tool-authz --ignore-not-found
kc -n "$MCP_NS" delete pod mcp-authz-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
ok "reverted — all tools visible again"
log "re-run ./scripts/90-mcp-agent.sh to see the unrestricted tools/list"
