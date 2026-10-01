#!/usr/bin/env bash
# 87-vsr-routes.sh — two model routes behind one gateway, chosen per prompt by
# vLLM Semantic Router (VSR):
#
#   gemma   Gemma 3 27B on the H100 in this cluster (60-model.sh). Computer
#           science and finance (plus law, health, psychology) always land here.
#           Never leaves Berlin.
#   gemini  Gemini 2.5 Flash, Google's frontier model, for non-sensitive general
#           questions. Leaves the boundary through Cloud NAT, by policy.
#
# It all lives on a SECOND Gateway, agentgateway-models, at models.$BASE_DOMAIN.
# VSR is an extProc with buffered bodies; on agentgateway-proxy it would buffer
# the MCP SSE streams too. See yaml/vsr/gateway.yaml.
#
#   GEMINI_API_KEY=... ./scripts/87-vsr-routes.sh        install + test
#   LB=1 ./scripts/87-vsr-routes.sh                      also an internal LB + DNS
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
GW_NAME=agentgateway-models
HOST="models.${BASE_DOMAIN}"
VSR_CHART="${VSR_CHART:-oci://ghcr.io/vllm-project/charts/semantic-router}"
VSR_VERSION="${VSR_VERSION:-0.3.0}"
VSR_DIR="$SCRIPT_DIR/../yaml/vsr"
PORT="${VSR_PF_PORT:-18091}"

gw_svc() {
  kc -n "$NS" get svc -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── test: auto, then each route forced ───────────────────────────────────────
run_tests() {
  local svc; svc="$(gw_svc)"
  [[ -n "$svc" ]] || die "no Service for Gateway $NS/$GW_NAME — run this script without 'test' first"
  kc -n "$NS" port-forward "svc/$svc" "${PORT}:80" >/dev/null 2>&1 &
  local pf=$!
  trap 'kill '"$pf"' 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT" && break; sleep 0.5; done

  ask() {  # label  model  header  prompt
    local hdr=() body resp
    [[ -n "$3" ]] && hdr=(-H "x-selected-model: $3")
    body="$(jq -n --arg m "$2" --arg p "$4" '{model:$m, max_tokens:80, messages:[{role:"user",content:$p}]}')"
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
  ask auto   auto "" "Plan a two-day programme for an international delegation visiting Berlin."
  ask gemma  gemma-3-27b-it   gemma-3-27b-it   "Say hello from Berlin in one sentence."
  ask gemini gemini-2.5-flash gemini-2.5-flash "Say hello from Gemini in one sentence."
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
log "waiting for the router (first start downloads its models; up to 30m)"
kc -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=1800s
ok "semantic-router Available"

# ── 3. gateway, backends, policy, routes ─────────────────────────────────────
step "Gateway $GW_NAME, backends gemma + gemini, extProc policy, HTTPRoute"
for f in gateway backends extproc-policy routes; do
  sed "s/__BASE_DOMAIN__/${BASE_DOMAIN}/g" "$VSR_DIR/$f.yaml" | kc apply -f - >/dev/null
done
kc -n "$NS" wait --for=condition=Programmed "gateway/$GW_NAME" --timeout=300s
ok "Gateway programmed"
kc -n "$NS" get agentgatewaybackend gemma gemini >&2
kc -n "$NS" get httproute models -o jsonpath='{range .status.parents[*].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' >&2

# ── 4. optional: an internal LB, same pattern as 80-ingress.sh ──────────────
if [[ "${LB:-0}" == 1 ]]; then
  step "internal LoadBalancer for $HOST"
  SVC="$(gw_svc)"
  kc -n "$NS" annotate svc "$SVC" --overwrite \
    'cloud.google.com/neg={"exposed_ports":{"80":{}}}' \
    'networking.gke.io/load-balancer-type=Internal' >/dev/null
  kc -n "$NS" patch svc "$SVC" -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
  is_private_ip() {
    case "$1" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
      *) return 1 ;;
    esac
  }
  LB_IP=""
  for _ in $(seq 1 60); do
    CAND="$(kc -n "$NS" get svc "$SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    # Skip a transient external address; see 80-ingress.sh.
    if [[ -n "$CAND" ]] && is_private_ip "$CAND"; then LB_IP="$CAND"; break; fi
    sleep 5
  done
  [[ -n "$LB_IP" ]] || die "no internal LB address for svc/$SVC after 5m"
  dns_upsert "$HOST" "$LB_IP"
  ok "$HOST -> $LB_IP"
fi

run_tests

cat >&2 <<MSG

  Two routes are live on $HOST:
    sovereign (computer science, business, economics, law, health, psychology) -> Gemma, in Berlin
    frontier  (math, physics, history, philosophy, other)                      -> Gemini, via Cloud NAT
  Anything unclassified, or any request while the router is down, goes to Gemma.

  Console: http://localhost:8900/google
MSG
