#!/usr/bin/env bash
# 67-accesspolicy-setup.sh — stand up the waypoint-governed agent path, where
# Solo's AccessPolicy decides which tools an agent may call.
#
# This is the second of two agent topologies in this stack, and they are NOT
# interchangeable:
#
#   standalone agentgateway   the agent reaches a URL; policy is authored
#   (90-mcp-agent.sh,         directly as AgentgatewayPolicy on the gateway.
#    95-authz-on.sh)          Works with NO mesh, so it is the fallback for a
#                             customer who cannot use privileged allowlisting.
#
#   waypoint  (this script)   kmcp owns the tool server, the enterprise
#                             agentgateway waypoint sits in front, and
#                             AccessPolicy compiles into the enforcement
#                             objects. Requires Istio ambient.
#
# Three constraints discovered the hard way, all encoded here:
#
#   1. AccessPolicy tool-scoping resolves a kagent MCPServer, not a
#      RemoteMCPServer. A RemoteMCPServer is only a URL, so there is nothing to
#      attach a policy to.
#   2. The kagent namespace is RESERVED for policies. Governed agents and tool
#      servers must live elsewhere, hence AGENTS_NS.
#   3. The generated Istio policy names only the SUBJECT's identity, but the
#      client of the tool server is the WAYPOINT. Without a companion policy the
#      hop is refused, discovery silently returns nothing, and the waypoint
#      misreports it as a 401 from the tool server. See
#      feedback/solo/01-accesspolicy-waypoint-hop.md.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

AGENTS_NS="${AGENTS_NS:-agents}"
KAGENT_NS="${KAGENT_NS:-kagent}"
MCP_NS="${MCP_NS:-mcp}"
YAML_DIR="$LAB_ROOT/istio-ambient/accesspolicies"

require kubectl

step "Preflight"
kubectl -n istio-system get ds ztunnel >/dev/null 2>&1 \
  || die "Istio ambient is not installed. Run 62, 63 and 64 first;
    AccessPolicy has nothing to compile onto without a mesh."
T="$(kubectl -n "$KAGENT_NS" get deploy kagent-controller \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ENABLE_ISTIO_AUTHZ_TRANSLATION")]}{.value}{end}' 2>/dev/null)"
if [[ "$T" != "true" ]]; then
  die "kagent's Istio authz translation is off (ENABLE_ISTIO_AUTHZ_TRANSLATION=${T:-unset}).
    AccessPolicy will never compile. Re-run 40-kagent.sh, which sets
    controller.istioAuthzTranslation.enabled=true by default."
fi
ok "ambient present and kagent translation enabled"

step "Namespace $AGENTS_NS"
kubectl create ns "$AGENTS_NS" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
# Enrol at creation rather than retroactively: the workloads below need a
# workload identity from their first breath, because an ALLOW policy denies
# anything it cannot identify.
kubectl label ns "$AGENTS_NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1
ok "$AGENTS_NS created and enrolled in ambient"

step "Credentials the governed workloads need"
# The in-universe registry is not covered by the node credential provider, so
# the pull secret has to be explicit and present in this namespace.
copy_secret() {  # copy_secret <from-ns> <name>
  kubectl -n "$1" get secret "$2" -o json 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':'$2','namespace':'$AGENTS_NS'}
d.pop('status',None)
print(json.dumps(d))" 2>/dev/null \
    | kubectl apply -f - >/dev/null 2>&1 \
    && ok "$2 copied from $1" || warn "could not copy secret $2 from $1"
}
copy_secret "$MCP_NS" ar-pull
copy_secret "$KAGENT_NS" llm-key

# The ModelConfig is namespaced, and a declarative Agent resolves it in its own
# namespace, so it has to exist here too.
kubectl -n "$KAGENT_NS" get modelconfig selfhosted -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':'selfhosted','namespace':'$AGENTS_NS'}
d.pop('status',None)
print(json.dumps(d))" 2>/dev/null \
  | kubectl apply -f - >/dev/null 2>&1 \
  && ok "ModelConfig/selfhosted copied" || warn "could not copy the ModelConfig"

step "Waypoint-fronted MCPServer and agent"
kubectl apply -f "$YAML_DIR/09-mcpserver-waypoint.yaml" >/dev/null 2>&1 \
  || die "could not apply the MCPServer and Agent"
for _ in $(seq 1 24); do
  M="$(kubectl -n "$AGENTS_NS" get mcpserver everything-server \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [[ "$M" == "True" ]] && break
  sleep 10
done
[[ "$M" == "True" ]] && ok "MCPServer Ready, waypoint provisioned" \
  || die "MCPServer did not become Ready. Check:
    kubectl -n $AGENTS_NS describe mcpserver everything-server"

step "Companion policy for the waypoint hop"
# MUST be applied BEFORE the AccessPolicy. Applied after, the generated Istio
# policy blocks discovery in the window between, and the MCPServer caches an
# empty tool list.
kubectl apply -f "$YAML_DIR/11-waypoint-hop-allow.yaml" >/dev/null 2>&1 \
  && ok "waypoint and controller identities allowed to reach the tool server" \
  || die "could not apply the companion policy"

step "AccessPolicy"
kubectl apply -f "$YAML_DIR/10-tools-allow-sum-only.yaml" >/dev/null 2>&1 \
  || die "could not apply the AccessPolicy"
for _ in $(seq 1 12); do
  S="$(kubectl -n "$AGENTS_NS" get accesspolicy allow-sum-only \
       -o jsonpath='{.status.state}' 2>/dev/null)"
  [[ "$S" == "Applied" ]] && break
  sleep 10
done
if [[ "$S" == "Applied" ]]; then
  ok "AccessPolicy state=Applied"
else
  warn "AccessPolicy state=${S:-unset}"
  kubectl -n "$AGENTS_NS" get accesspolicy allow-sum-only \
    -o jsonpath='{.status.message}{"\n"}' 2>/dev/null | sed 's/^/    /' >&2
  die "AccessPolicy did not compile"
fi

step "What it compiled into"
kubectl -n "$AGENTS_NS" get enterpriseagentgatewaypolicy,authorizationpolicy 2>/dev/null \
  | sed 's/^/    /' >&2

step "Agent rollout"
# The agent caches its tool list at start-up, so it must come up AFTER the
# policies are in force or it will hold a stale list.
kubectl -n "$AGENTS_NS" rollout restart deploy/waypoint-calc >/dev/null 2>&1
kubectl -n "$AGENTS_NS" rollout status deploy/waypoint-calc --timeout=300s >/dev/null 2>&1 \
  && ok "waypoint-calc rolled out" || warn "waypoint-calc rollout did not complete"

step "Done"
log "verify with: ./scripts/69-accesspolicy-health.sh"
