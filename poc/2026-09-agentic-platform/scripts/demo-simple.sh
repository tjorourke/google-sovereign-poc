#!/usr/bin/env bash
# demo-simple.sh — five short, self-contained use cases for a Google audience.
# Everything goes through the ONE enterprise agentgateway, reached over a
# kubectl port-forward, so it runs from a laptop with no /etc/hosts edits and
# no external load balancer.
#
#   ./scripts/demo-simple.sh             all five, in order
#   ./scripts/demo-simple.sh labels      every pod we run carries company=trustusbank
#   ./scripts/demo-simple.sh routing     one gateway, routing by hostname
#   ./scripts/demo-simple.sh llm         chat with Gemma 3 27B on H100, through the gateway
#   ./scripts/demo-simple.sh mcp         MCP tools: the gateway filters what an agent can see and call
#   ./scripts/demo-simple.sh agent       a kagent agent: Gemma + an MCP tool, end to end
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl curl jq python3
load_env

BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
AGW_NS="${AGW_NS:-agentgateway-system}"
GW_SVC="${GW_SVC:-agentgateway-proxy}"
PORT="${DEMO_PORT:-18080}"
GW="http://127.0.0.1:${PORT}"

say()  { printf '\n\033[1;36m%s\033[0m\n' "$*" >&2; }
show() { printf '\033[2m$ %s\033[0m\n' "$*" >&2; }
pause() { [[ "${DEMO_PAUSE:-0}" == 1 ]] && { read -rp "  [enter] " _ </dev/tty; } || true; }

# ── port-forward to the gateway, torn down on exit ───────────────────────────
PF_PID=""
start_pf() {
  [[ -n "$PF_PID" ]] && return
  kc -n "$AGW_NS" port-forward "svc/$GW_SVC" "${PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "$GW" && return
    sleep 0.5
  done
  die "port-forward to svc/$GW_SVC in $AGW_NS did not come up"
}

# Strip SSE framing if the server answered with text/event-stream.
unsse() { sed -n 's/^data: //p; /^{/p' | head -1; }

# ── 1. labels ────────────────────────────────────────────────────────────────
demo_labels() {
  say "1. Every pod we run carries a company identifier"
  echo "  Google asked for it; Helm charts, kubectl applies and the gateway pods the" >&2
  echo "  controller creates at runtime all get ${COMPANY_LABEL_KEY}=${COMPANY_LABEL_VALUE}." >&2
  show "kubectl get pods -A -l ${COMPANY_LABEL_KEY}=${COMPANY_LABEL_VALUE} -L ${COMPANY_LABEL_KEY}"
  kc get pods -A -l "${COMPANY_LABEL_KEY}=${COMPANY_LABEL_VALUE}" \
    --field-selector=status.phase=Running -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,COMPANY:.metadata.labels.company' \
    | head -25 >&2
  echo "  ..." >&2
  "$SCRIPT_DIR/26-labels-health.sh" || warn "some pods are unlabelled (listed above)"
  pause
}

# ── 2. routing ───────────────────────────────────────────────────────────────
demo_routing() {
  start_pf
  say "2. One gateway, many backends: routing by hostname"
  show "kubectl get httproute -A"
  kc get httproute -A -o custom-columns='NAMESPACE:.metadata.namespace,ROUTE:.metadata.name,HOSTS:.spec.hostnames,BACKEND:.spec.rules[0].backendRefs[0].name' >&2

  echo >&2
  show "curl -H 'Host: llm.${BASE_DOMAIN}' $GW/v1/models"
  curl -sS -m 20 -H "Host: llm.${BASE_DOMAIN}" "$GW/v1/models" \
    | jq -r '"  -> model server answers: \(.data[0].id)"' >&2

  show "curl -H 'Host: mcp.${BASE_DOMAIN}' $GW/mcp   (MCP initialize)"
  curl -sS -m 20 -X POST -H "Host: mcp.${BASE_DOMAIN}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
    "$GW/mcp" | unsse | jq -r '"  -> MCP server answers: \(.result.serverInfo.name) \(.result.serverInfo.version)"' >&2

  show "curl -H 'Host: nothing.${BASE_DOMAIN}' $GW/"
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Host: nothing.${BASE_DOMAIN}" "$GW/")"
  echo "  -> HTTP $code: no route, no backend. Only what the platform team routed is reachable." >&2
  pause
}

# ── 3. LLM ───────────────────────────────────────────────────────────────────
demo_llm() {
  start_pf
  say "3. Gemma 3 27B, self-hosted on an H100 in Berlin, through agentgateway"
  local model prompt body t0 t1 resp
  model="$(curl -sS -m 20 -H "Host: llm.${BASE_DOMAIN}" "$GW/v1/models" | jq -r '.data[0].id')"
  [[ -n "$model" && "$model" != null ]] || die "llm.${BASE_DOMAIN} did not list a model — is 60-model.sh done?"
  prompt="${DEMO_PROMPT:-In two sentences: why would a German bank want its AI model to run inside a sovereign cloud?}"
  body="$(jq -n --arg m "$model" --arg p "$prompt" '{model:$m, max_tokens:160, messages:[{role:"user",content:$p}]}')"
  show "curl -H 'Host: llm.${BASE_DOMAIN}' $GW/v1/chat/completions  (model: $model)"
  echo "  Q: $prompt" >&2
  t0=$(python3 -c 'import time;print(time.time())')
  resp="$(curl -sS -m 120 -H "Host: llm.${BASE_DOMAIN}" -H 'Content-Type: application/json' \
            -d "$body" "$GW/v1/chat/completions")"
  t1=$(python3 -c 'import time;print(time.time())')
  jq -r '"  A: \(.choices[0].message.content)"' <<<"$resp" | fold -s -w 100 | sed '2,$s/^/     /' >&2
  jq -r --arg s "$(python3 -c "print(round($t1-$t0,2))")" \
    '"\n  \(.usage.completion_tokens) tokens in \($s)s  (\((.usage.completion_tokens / ($s|tonumber)) | floor) tok/s)  — no external inference API, nothing left the boundary"' \
    <<<"$resp" >&2
  pause
}

# ── 4. MCP ───────────────────────────────────────────────────────────────────
mcp_post() {  # id-less notifications return nothing; that is fine
  curl -sS -m 20 -X POST -H "Host: mcp.${BASE_DOMAIN}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    ${SID:+-H "Mcp-Session-Id: $SID"} -d "$1" "$GW/mcp"
}
demo_mcp() {
  start_pf
  say "4. MCP: the gateway decides which tools an agent can see and call"
  show "kubectl -n agents get agentgatewaypolicy mcp-tool-authz -o yaml   (the grant)"
  kc get agentgatewaypolicy -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.backend.mcp.authorization) | .spec.backend.mcp.authorization.policy.matchExpressions[] | "    allow if: \(.)"' >&2

  SID="$(curl -sS -m 20 -D - -o /dev/null -X POST -H "Host: mcp.${BASE_DOMAIN}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
    "$GW/mcp" | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
  [[ -n "$SID" ]] || die "MCP initialize returned no session id"
  mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

  echo >&2
  show "tools/list"
  echo "  The server offers: sum, echo, printenv, ... — the caller sees only:" >&2
  mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | unsse \
    | jq -r '.result.tools[] | "    - \(.name)"' >&2

  show "tools/call sum {a:2, b:3}"
  mcp_post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sum","arguments":{"a":2,"b":3}}}' | unsse \
    | jq -r '"  -> \(.result.content[0].text // .error.message)"' >&2

  show "tools/call printenv   (would leak the server's environment)"
  mcp_post '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"printenv","arguments":{}}}' | unsse \
    | jq -r '"  -> denied: \(.error.message // .result.content[0].text) (code \(.error.code // "-"))"' >&2
  echo "  Same server, same request — the gateway removed the tool. No agent or server change." >&2
  pause
}

# ── 5. agent ─────────────────────────────────────────────────────────────────
demo_agent() {
  say "5. A kagent agent: Gemma reasons, calls an MCP tool through the gateway"
  if [[ -x "$SCRIPT_DIR/57-ar-ask.sh" ]]; then
    "$SCRIPT_DIR/57-ar-ask.sh" "${DEMO_AGENT_PROMPT:-What is 1234 plus 4321? Use your tool.}"
  else
    warn "57-ar-ask.sh not found; skipping"
  fi
}

case "${1:-all}" in
  labels)  demo_labels ;;
  routing) demo_routing ;;
  llm)     demo_llm ;;
  mcp)     demo_mcp ;;
  agent)   demo_agent ;;
  all)     demo_labels; demo_routing; demo_llm; demo_mcp; demo_agent ;;
  *)       die "usage: $0 [labels|routing|llm|mcp|agent|all]" ;;
esac
