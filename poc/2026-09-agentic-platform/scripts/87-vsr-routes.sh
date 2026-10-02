#!/usr/bin/env bash
# 87-vsr-routes.sh — two model routes behind one gateway, chosen per prompt by
# vLLM Semantic Router (VSR):
#
#   gemma   Gemma 3 27B on the H100 in this cluster (60-model.sh). Computer
#           science and finance (plus law, health, psychology) always land here.
#           Never leaves Berlin.
#   gemini  Gemini 3.8 Flash, Google's frontier model, for non-sensitive general
#           questions. Leaves the boundary through Cloud NAT, by policy.
#
# One agentgateway, one Deployment, one address. The model endpoint is a
# ListenerSet on agentgateway-proxy (yaml/vsr/listenerset.yaml): its own listener
# for agw.$BASE_DOMAIN, so the VSR extProc (buffered bodies, PreRouting) can be
# scoped to that listener and never touches the MCP SSE streams on mcp.*.
#
#   GEMINI_API_KEY=... ./scripts/87-vsr-routes.sh        install + test
#
# agw.$BASE_DOMAIN shares agentgateway-proxy's internal LB (private DNS points at
# it) and its external one (./scripts/hosts.sh maps it on a laptop).
#   ./scripts/87-vsr-routes.sh test                      just the three test calls
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl helm curl jq
load_env
assert_universe

BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
NS="${AGW_NS:-agentgateway-system}"
GW="${AGW_GATEWAY:-agentgateway-proxy}"
LS_NAME=agentgateway-models
HOST="agw.${BASE_DOMAIN}"
VSR_CHART="${VSR_CHART:-oci://ghcr.io/vllm-project/charts/semantic-router}"
VSR_VERSION="${VSR_VERSION:-0.3.0}"
VSR_DIR="$SCRIPT_DIR/../yaml/vsr"
PORT="${VSR_PF_PORT:-18091}"

# The gateway's own Service (its external twin carries the same label).
gw_svc() {
  kc -n "$NS" get svc -l "gateway.networking.k8s.io/gateway-name=$GW" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v -- '-external$' | head -1
}

# ── test: auto, then each route forced ───────────────────────────────────────
run_tests() {
  local svc; svc="$(gw_svc)"
  [[ -n "$svc" ]] || die "no Service for Gateway $NS/$GW — run 80-ingress.sh first"
  kc -n "$NS" port-forward "svc/$svc" "${PORT}:80" >/dev/null 2>&1 &
  local pf=$!
  trap 'kill '"$pf"' 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT" && break; sleep 0.5; done

  ask() {  # label  model  header  prompt
    local hdr=() body resp
    [[ -n "$3" ]] && hdr=(-H "x-selected-model: $3")
    body="$(jq -n --arg m "$2" --arg p "$4" '{model:$m, max_tokens:1500, messages:[{role:"user",content:$p}]}')"
    resp="$(curl -sS -m 180 -D /tmp/vsr-h.$$ -H "Host: $HOST" -H 'Content-Type: application/json' \
              ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$PORT/v1/chat/completions" || true)"
    printf '\n  %-7s %s\n' "$1" "$4" >&2
    tr -d '\r' </tmp/vsr-h.$$ | grep -i '^x-vsr-\|^HTTP/' | sed 's/^/          /' >&2
    jq -r '"          model: \(.model // "-")\n          -> \((.choices[0].message.content // .error.message // .error // "no answer") | tostring | .[0:160])"' \
      <<<"$resp" >&2 2>/dev/null || echo "          -> ${resp:0:200}" >&2
    rm -f /tmp/vsr-h.$$
  }
  step "four calls through $HOST"
  ask auto   auto "" "Write a Python function that merges overlapping intervals."
  ask auto   auto "" "Plan a two-day cultural visit to Berlin for an international delegation: museums, a concert and a riverside walk."
  ask gemma  gemma-3-27b-it   gemma-3-27b-it   "Say hello from Berlin in one sentence."
  ask gemini gemini-3.8-flash gemini-3.8-flash "Say hello from Gemini in one sentence."
  echo >&2
  ok "first auto call should be Gemma (computer science), second Gemini (other)"
}

if [[ "${1:-}" == test ]]; then run_tests; exit 0; fi

# ── 1. secrets ───────────────────────────────────────────────────────────────
# Both are plain Kubernetes Secrets: GCD has no Secret Manager (see lib.sh).
step "secrets"
# The router's classifiers are ungated; the token only lifts Hugging Face's
# anonymous rate limit on the first download.
if [[ -n "${HF_TOKEN:-}" ]]; then
  kc -n "$NS" create secret generic hf-token-secret --from-literal=token="$HF_TOKEN" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
fi
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  # agentgateway sends the Secret's Authorization field upstream verbatim, so it
  # carries the Bearer prefix. The console and every client never hold the key.
  kc -n "$NS" create secret generic gemini-secret --from-literal=Authorization="Bearer $GEMINI_API_KEY" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "gemini-secret"
else
  kc -n "$NS" get secret gemini-secret >/dev/null 2>&1 \
    && ok "gemini-secret already present" \
    || warn "GEMINI_API_KEY unset and no gemini-secret: the gemini route will answer 401. Gemma still works."
fi

# ── 2. the router ────────────────────────────────────────────────────────────
step "vLLM Semantic Router $VSR_VERSION"
clear_failed_release semantic-router "$NS"
# No --wait: the first start downloads several GB of classifier weights and
# helm's timeout would race it. Wait on the Deployment instead.
helm --kube-context "$(kube_context)" upgrade --install semantic-router "$VSR_CHART" \
  -n "$NS" --version "$VSR_VERSION" \
  -f "$VSR_DIR/values.yaml" \
  $(company_labels)
# Recreate, not the chart's RollingUpdate: the model cache is a ReadWriteOnce
# disk, so a rolling update starts the new pod while the old one still holds the
# volume, and it sits in Multi-Attach until the progress deadline. The chart has
# no strategy value; patching straight after upgrade also unsticks a rollout
# that is already waiting.
kc -n "$NS" patch deploy semantic-router --type=merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' >/dev/null
log "waiting for the router (first start downloads its models; up to 30m)"
kc -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=1800s
ok "semantic-router Available"

# ── 3. listener, backends, policy, routes ────────────────────────────────────
step "ListenerSet $LS_NAME on Gateway $GW, backends gemma + gemini, extProc policy, HTTPRoute"
kc -n "$NS" get gateway "$GW" >/dev/null 2>&1 || die "Gateway $NS/$GW missing — run 80-ingress.sh first"
# A Gateway accepts no ListenerSets until it opts in. 80-ingress.sh sets this
# too; patching here keeps the phase working on a Gateway made before that.
kc -n "$NS" patch gateway "$GW" --type=merge \
  -p '{"spec":{"allowedListeners":{"namespaces":{"from":"Same"}}}}' >/dev/null
for f in listenerset backends extproc-policy routes; do
  manifest="$VSR_DIR/$f.yaml"
  # A router upgrade must not undo the installed data residency rules.
  if [[ "$f" == routes ]] && kc -n "$NS" get agentgatewaypolicy trustusbank-data-class >/dev/null 2>&1; then
    manifest="$LAB_ROOT/yaml/dlp/05-routes.yaml"
  fi
  sed "s/__BASE_DOMAIN__/${BASE_DOMAIN}/g" "$manifest" | kc apply -f - >/dev/null
done
# https alongside http once 85-tls.sh has issued the edge certificate (whose
# HOSTS include agw). Added by patch so a rerun of the apply above, which
# declares http only, is followed by putting it straight back.
if kc -n "$NS" get secret agentic-edge-tls >/dev/null 2>&1; then
  kc -n "$NS" get listenerset "$LS_NAME" -o jsonpath='{.spec.listeners[*].name}' | grep -qw https \
    || kc -n "$NS" patch listenerset "$LS_NAME" --type=json -p '[{
      "op":"add","path":"/spec/listeners/-","value":{
        "name":"https","protocol":"HTTPS","port":443,"hostname":"'"$HOST"'",
        "tls":{"mode":"Terminate","certificateRefs":[{"kind":"Secret","name":"agentic-edge-tls"}]},
        "allowedRoutes":{"namespaces":{"from":"Same"}}}}]' >/dev/null
fi
kc -n "$NS" wait --for=condition=Accepted "listenerset/$LS_NAME" --timeout=120s >/dev/null \
  || { kc -n "$NS" get listenerset "$LS_NAME" -o yaml >&2; die "ListenerSet $LS_NAME not accepted by $GW"; }
kc -n "$NS" wait --for=condition=Programmed "listenerset/$LS_NAME" --timeout=300s >/dev/null
ok "ListenerSet programmed: $(kc -n "$NS" get listenerset "$LS_NAME" -o jsonpath='{range .spec.listeners[*]}{.name}:{.port} {end}')"
kc -n "$NS" get agentgatewaybackend gemma gemini >&2
kc -n "$NS" get httproute models -o jsonpath='{range .status.parents[*].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' >&2

# ── 4. private DNS: agw shares the gateway's internal LB ────────────────────
LB_IP="$(kc -n "$NS" get svc "$(gw_svc)" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
case "$LB_IP" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
    dns_upsert "$HOST" "$LB_IP"; ok "$HOST -> $LB_IP (private zone)" ;;
  *) warn "no internal LB address on $GW yet; $HOST not in private DNS (rerun after 80-ingress.sh)" ;;
esac

run_tests

cat >&2 <<MSG

  Two routes are live on $HOST:
    sovereign (computer science, business, economics, law, health, psychology) -> Gemma, in Berlin
    frontier  (math, physics, history, philosophy, other)                      -> Gemini, via Cloud NAT
  Anything unclassified, or any request while the router is down, goes to Gemma.

  Console: http://localhost:8900/google
MSG
