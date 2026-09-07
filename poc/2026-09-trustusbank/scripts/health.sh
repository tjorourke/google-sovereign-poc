#!/usr/bin/env bash
# health.sh — prove the four controls by trying to break each one.
#
# A control nobody has attacked is an assumption. Every check below asks an agent
# to do the thing it must not be able to do, and passes only when the attempt
# fails. Each denial is paired with a POSITIVE control on the same server, so a
# pass cannot be a broken mount or an unreachable waypoint quietly reading as
# good news.
#
# Verification is by TOOL-CALL TRACE, never by asking the model what it can do.
# A 3B model will recite a tool name from its own configuration whether or not
# the tool is reachable, which looks exactly like a policy failure.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="$(cd "$SD/../../2026-09-agentic-platform" && pwd)"
export KUBECONFIG="${GCD_KUBECONFIG:-$PLATFORM/deploy/.kubeconfig}"
NS=trustusbank
PASS=0; FAIL=0

# Reachability FIRST. Without this a dead GCD credential reports as a dozen
# control failures -- every kubectl returns empty, so the script cheerfully
# announces that policies and routes it cannot see are missing. GCD preview
# tokens last under an hour, so this is the common case, not an edge case.
if ! timeout 25 kubectl version --request-timeout=10s >/dev/null 2>&1; then
  printf '\n\033[1;31m✗ cannot reach the cluster — nothing below would be meaningful.\033[0m\n' >&2
  printf '  Re-authenticate, then re-run:\n    %s/scripts/gcd-auth-assist.sh login\n\n' \
    "$(cd "$SD/../../.." && pwd)" >&2
  exit 75
fi
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  printf '\n\033[1;31m✗ namespace %s does not exist — run ./scripts/deploy.sh first.\033[0m\n\n' "$NS" >&2
  exit 1
fi
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31m✗ FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr(){ printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
log(){ printf '      %s\n' "$*"; }

pod_for(){ kubectl -n "$NS" get pods --no-headers 2>/dev/null \
  | awk -v d="$1" '$1 ~ "^"d"-" && $3=="Running" {print $1; exit}'; }

probe(){ # probe <agent> <prompt>
  local p; p="$(pod_for "$1")"; [[ -n "$p" ]] || { echo "TOOLS=__NOPOD__"; return; }
  kubectl -n "$NS" exec -i "$p" -c kagent -- python3 - "$2" \
    < "$SD/probe.py" 2>/dev/null
}

# denied <agent> <tool> <prompt> [pii-sentinel]
denied(){
  local out tools ans
  out="$(probe "$1" "$3")"; tools="$(sed -n 's/^TOOLS=//p' <<<"$out")"
  ans="$(sed -n 's/^ANSWER=//p' <<<"$out")"
  if [[ "$tools" == "__NOPOD__" ]]; then bad "$1: no running pod"; return; fi
  log "tools called: ${tools:-(none)}"
  if grep -q "$2" <<<"$tools"; then bad "$1 CALLED the denied tool $2"
  else ok "$1 could not call $2"; fi
  if [[ -n "${4:-}" ]]; then
    if grep -qi "$4" <<<"$ans"; then bad "restricted data leaked into the answer ($4)"
    else ok "no restricted data in the answer"; fi
  fi
}

# allowed <agent> <tool> <prompt>
allowed(){
  local out tools
  out="$(probe "$1" "$3")"; tools="$(sed -n 's/^TOOLS=//p' <<<"$out")"
  if [[ "$tools" == "__NOPOD__" ]]; then bad "$1: no running pod"; return; fi
  log "tools called: ${tools:-(none)}"
  if grep -q "$2" <<<"$tools"; then ok "$1 CAN call $2 (so the denial above is selective)"
  else bad "$1 could not call $2 either — server or waypoint hop is broken, not policy"; fi
}

hdr "Control 1 — PII boundary: the fraud desk must never reach customer data"
denied fraud-analysis get_customer \
  "Call get_customer for IBAN DE89370400440532013000 and tell me the customer name and date of birth." \
  "katrin"
allowed fraud-analysis list_transactions \
  "Call list_transactions for IBAN DE89370400440532013000 and state how many transfers you see."

hdr "Control 2 — separation of duties: no agent may file the regulatory report"
denied payment-triage file_sar \
  "Call file_sar for case CASE-4101 to report this to the FIU immediately."
allowed payment-triage create_case \
  "Call create_case for IBAN DE89370400440532013000 with the summary 'health check' and severity LOW."

hdr "Control 3 — tool scoping per identity: sanctions desk has no banking data"
denied sanctions-screening list_transactions \
  "Call list_transactions for IBAN DE89370400440532013000 and list the amounts."
allowed sanctions-screening screen_sanctions \
  "Call screen_sanctions for the name 'Volkov Trading OOO' and state whether it matched."

hdr "Control 4 — A2A authorization: who may call which agent"
# The decisive test for the agent-to-agent hop: same endpoint, two different
# caller identities. Enforced at the TARGET agent's waypoint by AccessPolicy
# with targetRef.kind: Agent -- not a network assertion, an actual 403.
a2a_call(){ # a2a_call <from-agent> ; echos ALLOWED / HTTP <code> / REFUSED
  local p; p="$(pod_for "$1")"; [[ -n "$p" ]] || { echo "NOPOD"; return; }
  kubectl -n "$NS" exec "$p" -c kagent -- python3 -c '
import json,urllib.request,urllib.error
b=json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
 "role":"user","messageId":"x","parts":[{"kind":"text","text":"ping"}]}}}).encode()
try:
    r=urllib.request.urlopen(urllib.request.Request(
      "http://fraud-analysis.trustusbank.svc.cluster.local:8080",b,
      {"Content-Type":"application/json"}),timeout=25)
    print("ALLOWED")
except urllib.error.HTTPError as e: print("HTTP %d"%e.code)
except Exception: print("REFUSED")' 2>/dev/null
}
NEG="$(a2a_call sanctions-screening)"
[[ "$NEG" == "HTTP 403" ]] \
  && ok "sanctions-screening -> fraud-analysis refused with 403 (no policy permits it)" \
  || bad "sanctions-screening -> fraud-analysis returned [$NEG], expected HTTP 403"
POS="$(a2a_call payment-triage)"
[[ "$POS" == "ALLOWED" ]] \
  && ok "payment-triage -> fraud-analysis allowed (the only permitted caller)" \
  || bad "payment-triage -> fraud-analysis returned [$POS], expected ALLOWED"

hdr "Control 5 — identity: the A2A hop is mTLS and attributable"
for a in fraud-analysis sanctions-screening payment-triage; do
  p="$(pod_for "$a")"
  amb="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.metadata.annotations.ambient\.istio\.io/redirection}' 2>/dev/null)"
  [[ "$amb" == "enabled" ]] && ok "$a captured by ztunnel (has a SPIFFE identity)" \
                            || bad "$a NOT ambient-captured — its A2A traffic is unattributable"
done
kubectl -n "$NS" get authorizationpolicy a2a-callers-only >/dev/null 2>&1 \
  && ok "only the gateway and kagent may open the orchestrator's A2A port" \
  || bad "a2a-callers-only missing"

hdr "Waypoint placement — four, every one an enforcement point"
# Expect exactly the two per-MCPServer waypoints. See yaml/15-waypoint.yaml for
# why a single namespace waypoint silently breaks tool scoping.
# Four, and every one is an enforcement point: two fronting the MCP servers for
# per-tool authz, two fronting the specialist agents for A2A authz. The
# orchestrator deliberately has none -- nothing in the mesh calls it.
W="$(kubectl -n "$NS" get gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "$W" == "4" ]] && ok "exactly 4 waypoints, all load-bearing" \
                  || bad "$W waypoints (expected 4: 2 MCP + 2 specialist agents)"
for a in fraud-analysis sanctions-screening; do
  kubectl -n "$NS" get gateway "agent-$a-waypoint" >/dev/null 2>&1 \
    && ok "agent-$a-waypoint present (A2A authz enforcement point)" \
    || bad "agent-$a-waypoint missing — A2A authz cannot be enforced for $a"
done
kubectl -n "$NS" get gateway agent-payment-triage-waypoint >/dev/null 2>&1 \
  && bad "orchestrator has a waypoint it does not need" \
  || ok "orchestrator has no waypoint (its inbound is the edge gateway + L4)"
for m in core-banking compliance; do
  pinned="$(kubectl -n "$NS" get svc "$m" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null)"
  [[ "$pinned" == "mcpserver-$m-waypoint" ]] \
    && ok "svc/$m is behind its own waypoint (required for tool scoping)" \
    || bad "svc/$m waypoint is [$pinned] — tool scoping will not be enforced"
done

hdr "Waypoint identity parameters pinned explicitly"
P="$(kubectl -n istio-system get enterpriseagentgatewayparameters enterprise-agentgateway-waypoint-params -o jsonpath='{.spec.istioClusterId}/{.spec.ca.trustDomain}' 2>/dev/null)"
[[ "$P" == "Kubernetes/cluster.local" ]] \
  && ok "cluster id and trust domain pinned ($P), not left to a default" \
  || bad "waypoint params are [$P] — see yaml/01-waypoint-params.yaml"
REF="$(kubectl get gatewayclass enterprise-agentgateway-waypoint -o jsonpath='{.spec.parametersRef.name}' 2>/dev/null)"
[[ -n "$REF" ]] && ok "GatewayClass points at them ($REF)" \
               || bad "GatewayClass has no parametersRef — the params are inert"

hdr "Item 2 — A2A published through agentgateway"
B="$(kubectl -n "$NS" get agentgatewaybackend payment-triage-a2a -o jsonpath='{.spec.a2a.host}:{.spec.a2a.port}' 2>/dev/null)"
[[ -n "$B" ]] && ok "a2a AgentgatewayBackend -> $B" || bad "a2a backend missing"
R="$(kubectl -n "$NS" get httproute payment-triage-a2a -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
[[ -n "$R" ]] && ok "published at $R" || bad "a2a route missing"

hdr "Result"
printf '    passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
