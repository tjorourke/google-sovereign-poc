#!/usr/bin/env bash
# 68-agent-mesh-policies.sh — put the real agent flows under ambient policy, and
# verify the platform still works at every step.
#
# What this proves, and why it is the interesting part of the whole stack:
#
#   agentgateway decides WHICH tools and models an agent may use. It cannot stop
#   an agent going around it. Ambient can. After this runs, the model and the
#   tool server accept connections from the gateway's identity and nothing else,
#   so tool-level authorization stops being advisory and becomes structural.
#
# This script is deliberately cautious, because an ALLOW policy denies everything
# it does not name and a mistake here takes the platform down:
#
#   1. Baseline the agent BEFORE changing anything. Abort if already broken.
#   2. Enrol the namespaces that carry agent traffic, one at a time, verifying
#      the agent after each.
#   3. Discover the gateway's real ServiceAccount rather than assuming it.
#   4. Apply the policies, then verify the agent AGAIN.
#   5. Prove a direct bypass of the gateway is now refused.
#   6. Roll back automatically if any verification fails.
#
# ROLLBACK: ./scripts/68-agent-mesh-policies.sh --rollback
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

YAML_DIR="$LAB_ROOT/istio-ambient/waypoint"
RENDERED="/tmp/agent-flow-policies.rendered.yaml"
# Namespaces that carry agent traffic and therefore need workload identity.
FLOW_NAMESPACES="${FLOW_NAMESPACES:-kagent model mcp agentgateway-system}"

rollback() {
  step "Rolling back"
  kubectl delete -f "$RENDERED" --ignore-not-found >/dev/null 2>&1
  ok "policies removed (namespace enrolment left in place; it is harmless on its own)"
}

if [[ "${1:-}" == "--rollback" ]]; then
  [[ -f "$RENDERED" ]] || die "no rendered policy file at $RENDERED; delete by name instead:
    kubectl -n model delete authorizationpolicy model-only-via-agentgateway
    kubectl -n mcp   delete authorizationpolicy mcp-only-via-agentgateway"
  rollback
  exit 0
fi

# Ask the AgentRegistry-deployed agent to use its governed tool. This is the
# end-to-end assertion: it exercises agent -> gateway -> model AND
# agent -> gateway -> MCP tool in one call.
agent_works() {
  local out
  out="$("$SD/57-ar-ask.sh" "Add 17 and 25 using your sum tool." 2>&1)"
  echo "$out" | grep -q '_sum({' && echo "$out" | grep -qi '42'
}

step "1. Baseline: does the agent work before we change anything?"
if agent_works; then
  ok "agent answers and calls its tool through agentgateway"
else
  die "the agent is not working BEFORE any change. Fix that first; do not
    layer mesh policy onto a broken platform."
fi

step "2. Enrolling the namespaces that carry agent traffic"
# Enrol one at a time and re-verify. agentgateway-system is the risky one: it
# carries every request in the platform, so if capture breaks anything we want
# to know at that exact step rather than after four changes.
for ns in $FLOW_NAMESPACES; do
  CUR="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)"
  if [[ "$CUR" == "ambient" ]]; then
    log "$ns already enrolled"
    continue
  fi
  kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1 \
    || { warn "could not label $ns"; continue; }
  sleep 10
  if agent_works; then
    ok "$ns enrolled, agent still working"
  else
    warn "agent broke after enrolling $ns — un-enrolling and stopping"
    kubectl label ns "$ns" istio.io/dataplane-mode- >/dev/null 2>&1
    sleep 10
    agent_works && ok "agent recovered after un-enrolling $ns" \
                || warn "agent still not working; investigate before retrying"
    die "stopped at namespace $ns"
  fi
done

step "3. Confirming every workload in the flow has an identity"
# A source with no identity is denied by an ALLOW policy. Capture is what gives
# it one, so check rather than assume.
MISSING=""
for ns in $FLOW_NAMESPACES; do
  while read -r pod redir; do
    [[ -z "$pod" ]] && continue
    [[ "$redir" == "enabled" ]] || MISSING="$MISSING $ns/$pod"
  done < <(kubectl -n "$ns" get pods --field-selector=status.phase=Running \
             -o custom-columns='P:.metadata.name,R:.metadata.annotations.ambient\.istio\.io/redirection' \
             --no-headers 2>/dev/null)
done
if [[ -n "$MISSING" ]]; then
  warn "not captured:$MISSING"
  warn "these will be DENIED by an ALLOW policy. Usually they predate enrolment;"
  warn "a rollout restart of the owning workload fixes it."
else
  ok "every running pod in the flow namespaces is captured"
fi

step "4. Discovering agentgateway's ServiceAccount"
AGW_SA="$(kubectl -n agentgateway-system get pods \
  -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy \
  -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null)"
[[ -n "$AGW_SA" ]] || AGW_SA="$(kubectl -n agentgateway-system get pods \
  -o jsonpath='{.items[?(@.metadata.labels.app\.kubernetes\.io/name=="agentgateway-proxy")].spec.serviceAccountName}' 2>/dev/null | awk '{print $1}')"
[[ -n "$AGW_SA" ]] || die "could not determine the agentgateway proxy ServiceAccount"
ok "agentgateway proxy runs as: $AGW_SA"
log "principal: cluster.local/ns/agentgateway-system/sa/$AGW_SA"

step "5. Applying the access policies"
sed "s|AGENTGATEWAY_SA|${AGW_SA}|g" \
  "$YAML_DIR/08-agent-flow-policies.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED" 2>&1 | sed 's/^/    /' >&2
sleep 10

step "6. Verifying the agent STILL works through the gateway"
if agent_works; then
  ok "agent answers and calls its tool, with the policies in force"
else
  warn "the agent broke with the policies applied"
  rollback
  die "policies rolled back. The usual cause is a workload in the flow that is
    not captured, so its traffic has no identity. See step 3 output."
fi

step "7. Proving the gateway can no longer be bypassed"
# Address the backing Services DIRECTLY, from a pod that is not the gateway.
# Before these policies this succeeded and every gateway control was skipped.
BYPASS_NS=kagent
kubectl -n "$BYPASS_NS" delete pod bypass-probe --ignore-not-found >/dev/null 2>&1
kubectl -n "$BYPASS_NS" run bypass-probe --image=curlimages/curl:8.11.0 \
  --restart=Never --command -- sleep 300 >/dev/null 2>&1
kubectl -n "$BYPASS_NS" wait --for=condition=Ready pod/bypass-probe --timeout=120s >/dev/null 2>&1

probe() {  # probe <url> -> http code, or 000 for a refused connection
  local out
  out="$(kubectl -n "$BYPASS_NS" exec bypass-probe -- \
    curl -s -o /dev/null -w '%{http_code}' -m 8 "$1" 2>/dev/null)"
  echo "${out:-000}"
}

MODEL_DIRECT="$(probe http://llm.model.svc.cluster.local:8000/v1/models)"
MCP_DIRECT="$(probe http://everything-server.mcp.svc.cluster.local:3000/mcp)"
VIA_GW="$(probe http://llm.agentic.eu0.internal/v1/models)"

log "direct to model Service      : $MODEL_DIRECT"
log "direct to MCP Service        : $MCP_DIRECT"
log "through agentgateway         : $VIA_GW"

FAILED=0
[[ "$MODEL_DIRECT" == "000" ]] && ok "direct model access refused at L4" \
  || { warn "direct model access returned $MODEL_DIRECT, expected 000"; FAILED=1; }
[[ "$MCP_DIRECT" == "000" ]] && ok "direct MCP access refused at L4" \
  || { warn "direct MCP access returned $MCP_DIRECT, expected 000"; FAILED=1; }
[[ "$VIA_GW" != "000" ]] && ok "the gateway path still works ($VIA_GW)" \
  || { warn "the gateway path is broken"; FAILED=1; }

kubectl -n "$BYPASS_NS" delete pod bypass-probe --ignore-not-found >/dev/null 2>&1

step "Result"
if [[ "$FAILED" -eq 0 ]]; then
  ok "agent flows verified: agentgateway is now the only route to the model and the tools"
  log "agentgateway  decides which tools and models an agent may use"
  log "ambient L4    guarantees it cannot go around agentgateway"
else
  warn "bypass prevention did not behave as expected; policies left in place for inspection"
  log "roll back with: $0 --rollback"
  exit 1
fi
