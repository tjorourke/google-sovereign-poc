#!/usr/bin/env bash
# 89-cost.sh — labelled Gemma/Gemini history and five editable demo budgets.
# seed fills new five-minute batches; it never clears live data or duplicates a
# completed batch. budget installs the five defaults (developer-daily: the demo
# user gets 2,500 Gemini tokens/day, Block; Gemma stays unmetered). After editing
# it in the UI, run seed rather than all to retain your edit.
# Historical ClickHouse spend and live gateway enforcement counters are separate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require kubectl python3
load_env
export KUBE_CONTEXT="${KUBE_CONTEXT:-$(kube_context)}"
export CH_NS="${CH_NS:-solo-enterprise}"
export CH_POD="${CH_POD:-solo-mgmt-clickhouse-shard0-0}"
AGW_NS="${AGW_NS:-agentgateway-system}"
LLM_NS="${LLM_NS:-model}"
LLM_ROUTE="${LLM_ROUTE:-llm}"
SEED_DAYS="${SEED_DAYS:-14}"
KC_ISSUER="${KC_ISSUER:-https://keycloak.agentic.eu0.internal/realms/agentregistry}"
KC_JWKS="${KC_JWKS:-http://keycloak.keycloak.svc.cluster.local/realms/agentregistry/protocol/openid-connect/certs}"
ROUTES=("$LLM_NS/$LLM_ROUTE" "$AGW_NS/models")
ch() { kc -n "$CH_NS" exec -i "$CH_POD" -c clickhouse -- clickhouse-client "$@"; }

seed() {
  step "seed: Gemma + Gemini, six users + the document batch pipeline, $SEED_DAYS days (~\$10K/30d)"
  python3 "$SCRIPT_DIR/seed_costs.py" --days "$SEED_DAYS"
}

budget() {
  step "budgets: developer daily, Finance, Development, Compliance, Platform"
  kc apply -f "$LAB_ROOT/yaml/cost/demo-budgets.yaml"
  # Replaces this script's earlier demo budgets. Apply the five new ones first,
  # so removing the legacy ones never leaves the demo user uncapped.
  kc -n "$AGW_NS" delete enterpriseagentgatewaybudget trustusbank bob-weekly --ignore-not-found
}

enforce() {
  local r ns name
  for r in "${ROUTES[@]}"; do
    ns="${r%/*}"; name="${r#*/}"
    kc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ${name}-identity-budget
  namespace: $ns
  labels: {company: trustusbank}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: $name
  traffic:
    # LLM-only policy: the existing callers use API-key placeholders. Strict
    # workload JWT authentication for MCP is managed separately by phase 92.
    jwtAuthentication:
      mode: Permissive
      providers:
      - issuer: $KC_ISSUER
        jwks:
          remote: {url: $KC_JWKS}
    entBudgetEnforcement:
      discovery:
        namespaces: {from: All}
EOF
  done
}

unenforce() {
  local r
  for r in "${ROUTES[@]}"; do
    kc -n "${r%/*}" delete enterpriseagentgatewaypolicy "${r#*/}-identity-budget" --ignore-not-found
  done
}

check() {
  step "cost totals: last $SEED_DAYS days"
  ch -q "SELECT dimension_id, dimension_value, countMerge(request_count) AS requests,
         round(toFloat64(sumMerge(spend_usd)),2) AS usd
         FROM platformdb.agw_cost_dimensions_5m
         WHERE dimension_id IN ('user','group','agent','model') AND bucket>now()-INTERVAL $SEED_DAYS DAY
         GROUP BY dimension_id,dimension_value ORDER BY dimension_id,usd DESC FORMAT PrettyCompact"
  kc -n "$AGW_NS" get enterpriseagentgatewaybudget \
    -o custom-columns='NAME:.metadata.name,SUBJECT:.spec.budgets[0].subject,LIMIT:.spec.budgets[0].limit.amount,WINDOW:.spec.budgets[0].window.unit,ACTION:.spec.budgets[0].onBudgetExceeded'
  ok "Cost Management: http://kagent.${BASE_DOMAIN:-agentic.eu0.internal}/age/cost-management"
}

case "${1:-all}" in
  seed) seed ;;
  budget) budget ;;
  enforce) enforce ;;
  unenforce) unenforce ;;
  check) check ;;
  all) seed; budget; enforce; check ;;
  *) die "usage: $0 [seed|budget|enforce|unenforce|check]" ;;
esac
