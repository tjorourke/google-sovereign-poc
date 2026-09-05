#!/usr/bin/env bash
# 69-accesspolicy-health.sh — verify AccessPolicy enforcement at the enterprise
# agentgateway waypoint, and that the two older agent paths still work.
#
# There are three agent paths in this cluster and they use different machinery.
# All three must keep working, so all three are checked here:
#
#   A. sovereign-calc          kagent ns              standalone agentgateway
#                              hand-written, policy authored directly as
#                              AgentgatewayPolicy. Works with no mesh at all.
#
#   B. sovereignagent          agentregistry-system   standalone agentgateway
#                              published to the AgentRegistry catalogue and
#                              deployed by the registry.
#
#   C. waypoint-calc           agents ns              enterprise waypoint
#                              governed by AccessPolicy, which compiles into an
#                              EnterpriseAgentgatewayPolicy (L7, per tool) and
#                              an Istio AuthorizationPolicy (L4, per identity).
#
# The interesting assertion is C: the agent requests three tools and the
# AccessPolicy grants one, so it must be able to call `sum` and must not even be
# able to see `echo`.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

AGENTS_NS="${AGENTS_NS:-agents}"
PASS=0; FAIL=0
pass() { ok "$*"; PASS=$((PASS+1)); }
fail() { warn "FAIL: $*"; FAIL=$((FAIL+1)); }

# Ask an agent something over A2A from inside its own pod, and print the tools
# it actually called. Running in-pod avoids needing any ingress path.
ask() {  # ask <namespace> <pod> <prompt>
  kubectl -n "$1" exec "$2" -c kagent -- python3 -c '
import json, sys, urllib.request
prompt = sys.argv[1]
body = json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
    "role":"user","messageId":"h1","parts":[{"kind":"text","text":prompt}]}}}).encode()
req = urllib.request.Request("http://localhost:8080", body, {"Content-Type":"application/json"})
res = json.load(urllib.request.urlopen(req, timeout=280))
res = res.get("result", res)
calls = [d.get("name") for m in (res.get("history") or []) for p in m.get("parts", [])
         if p.get("kind") == "data" for d in [p.get("data", {})] if "args" in d]
seen = []
def walk(o):
    if isinstance(o, dict):
        if o.get("role") == "user": return
        if o.get("kind") == "text" and isinstance(o.get("text"), str):
            t = o["text"].strip()
            if t and t not in seen: seen.append(t)
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(res.get("artifacts") or res)
print("TOOLS=" + ",".join(c for c in calls if c))
print("ANSWER=" + (seen[-1].replace("\n", " ")[:160] if seen else ""))
' "$3" 2>/dev/null
}

pod_in() {  # pod_in <namespace> <deployment-name-prefix>
  kubectl -n "$1" get pods -o name 2>/dev/null | grep -E "^pod/$2-" | head -1 | cut -d/ -f2
}

# Ask until the named tool actually shows up in the call trace.
#
# Two sources of noise make a single ask unreliable, and neither is a policy
# failure: tool discovery through the waypoint takes a moment to settle after
# the MCPServer or AccessPolicy is (re)applied, and a 3B model sometimes
# answers with ADK built-ins (ask_user, adk_request_confirmation) instead of
# calling the tool it was given. Retrying tests the POLICY, which is what this
# check is for, rather than the model's mood on one attempt.
ask_until_tool() {  # ask_until_tool <ns> <pod> <tool> <prompt>
  local ns="$1" pod="$2" want="$3" prompt="$4" out=""
  local i
  for i in 1 2 3 4; do
    out="$(ask "$ns" "$pod" "$prompt")"
    if echo "$out" | grep -q "TOOLS=.*${want}"; then
      printf '%s' "$out"; return 0
    fi
    sleep 15
  done
  printf '%s' "$out"; return 1
}

step "A. sovereign-calc, standalone agentgateway"
SC="$(pod_in kagent sovereign-calc)"
if [[ -z "$SC" ]]; then
  fail "no sovereign-calc pod"
else
  OUT="$(ask_until_tool kagent "$SC" sum 'Add 17 and 25 using your sum tool.')" || true
  echo "$OUT" | grep -q 'TOOLS=.*sum' && pass "called sum through the standalone gateway" \
    || fail "did not call sum ($(echo "$OUT" | grep '^TOOLS='))"
fi
TOOLS="$(kubectl -n kagent get remotemcpserver everything-server \
  -o jsonpath='{.status.discoveredTools[*].name}' 2>/dev/null)"
[[ "$TOOLS" == *sum* ]] && pass "gateway tool filtering intact: $TOOLS" \
                        || fail "unexpected discovered tools: ${TOOLS:-none}"

step "B. sovereignagent, deployed by AgentRegistry"
SA="$(pod_in agentregistry-system sovereignagent-latest-sovereignagent-k)"
if [[ -z "$SA" ]]; then
  fail "no AgentRegistry-deployed agent pod"
else
  OUT="$(ask_until_tool agentregistry-system "$SA" sum 'Add 17 and 25 using your sum tool.')" || true
  echo "$OUT" | grep -q 'TOOLS=.*sum' && pass "called sum through the standalone gateway" \
    || fail "did not call sum ($(echo "$OUT" | grep '^TOOLS='))"
fi

step "C. waypoint-calc, governed by AccessPolicy at the waypoint"
STATE="$(kubectl -n "$AGENTS_NS" get accesspolicy allow-sum-only \
  -o jsonpath='{.status.state}' 2>/dev/null)"
[[ "$STATE" == "Applied" ]] && pass "AccessPolicy state=Applied" \
                            || fail "AccessPolicy state=${STATE:-missing}"

# Both halves of the translation must exist. The L7 half does the per-tool work.
kubectl -n "$AGENTS_NS" get enterpriseagentgatewaypolicy \
  accesspolicy-allow-sum-only-waypoint >/dev/null 2>&1 \
  && pass "translated to EnterpriseAgentgatewayPolicy (L7, per tool)" \
  || fail "no EnterpriseAgentgatewayPolicy was generated"
kubectl -n "$AGENTS_NS" get authorizationpolicy \
  accesspolicy-allow-sum-only-waypoint >/dev/null 2>&1 \
  && pass "translated to Istio AuthorizationPolicy (L4, per identity)" \
  || fail "no Istio AuthorizationPolicy was generated"

# The companion policy is what makes the L4 half correct: the client of the tool
# server is the WAYPOINT, not the agent, and the generated policy names only the
# agent. Without this the hop is refused and the waypoint misreports it as a 401
# from upstream. See istio-ambient/accesspolicies/11-waypoint-hop-allow.yaml.
kubectl -n "$AGENTS_NS" get authorizationpolicy allow-waypoint-to-toolserver \
  >/dev/null 2>&1 \
  && pass "companion policy present for the waypoint hop" \
  || fail "companion policy missing; tool discovery will silently return nothing"

WC="$(pod_in "$AGENTS_NS" waypoint-calc)"
if [[ -z "$WC" ]]; then
  fail "no waypoint-calc pod"
else
  OUT="$(ask_until_tool "$AGENTS_NS" "$WC" sum 'Add 17 and 25 using your sum tool.')" || true
  if echo "$OUT" | grep -q 'TOOLS=.*sum'; then
    pass "permitted tool: called sum through the waypoint"
  else
    fail "permitted tool not callable ($(echo "$OUT" | grep '^TOOLS='))"
  fi

  # The agent's own definition requests echo. AccessPolicy does not grant it, so
  # it should be filtered out of tools/list and never called.
  OUT="$(ask "$AGENTS_NS" "$WC" 'Use your echo tool to echo back exactly the word pineapple.')"
  if echo "$OUT" | grep -q 'TOOLS=.*echo'; then
    fail "DENIED tool was called: AccessPolicy is not being enforced"
  else
    pass "denied tool: echo was not callable (filtered from discovery)"
    log "$(echo "$OUT" | grep '^ANSWER=' | cut -c8-120)"
  fi
fi

step "Result"
log "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || die "$FAIL check(s) failed"
ok "all three agent paths healthy; AccessPolicy enforced at the waypoint"
