#!/usr/bin/env bash
# 89-cost.sh — a week of TrustUsBank LLM spend, and a budget for bob.
#
# Cost Management (management 0.5.9, 45-telemetry.sh) breaks agentgateway spend
# down by the budgetDimensions 70-agentgateway.sh configures: user, team (group)
# and agent, all read from the JWT 88-identity.sh mints. A fresh lab has a few
# minutes of real traffic and no prices, so the page is empty. This fills it:
#
#   seed      ~7 days of LLM calls by bob (payments-ops) and alice (compliance)
#             through the four TrustUsBank agents, mostly Gemma 3 27B on the
#             H100 (model/llm), some Gemini 3.8 Flash through VSR. Rows go into
#             platformdb.agw_spans_typed, the table every Cost Management rollup
#             (agw_cost_dimensions_5m, agw_cost_model_5m, ...) is fed from, so
#             the materialized views aggregate them as if the proxy had sent them.
#             Seeded rows carry TraceId seed-*. The rollups cannot be un-merged,
#             so a second run skips the seed unless SEED_FORCE=1.
#   budget    an EnterpriseAgentgatewayBudget for bob (user=bob, USD per week,
#             Block) and one for his team, both editable on the Budgets page.
#   enforce   on both LLM routes (model/llm for the agents, agentgateway-system/
#             models for VSR): JWT authentication in Permissive mode, so a valid
#             Keycloak bearer is checked and its claims name the user, team and
#             agent in every span, while everything else still passes: the
#             console's Demo 1 sends no token, and the kagent agents send an
#             API-key bearer that is not a JWT at all (Optional mode rejects that
#             as malformed and broke every Demo 2 chat). Plus entBudgetEnforcement,
#             so a request attributed to bob is refused once his budget is spent.
#             Only the models route is priced: llm points at a plain Service, so
#             the proxy sees no model or tokens there (see TASKS.md 7).
#
#   ./scripts/89-cost.sh               all three
#   ./scripts/89-cost.sh seed|budget|enforce|check
#   ./scripts/89-cost.sh unenforce     remove both route policies
#
# Prices are illustrative chargeback rates, not list prices: Gemma is the H100's
# hourly cost spread over its tokens, Gemini roughly its public Flash rate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl python3
load_env

CH_NS="${CH_NS:-solo-enterprise}"
CH_POD="${CH_POD:-solo-mgmt-clickhouse-shard0-0}"
AGW_NS="${AGW_NS:-agentgateway-system}"
LLM_NS="${LLM_NS:-model}"
LLM_ROUTE="${LLM_ROUTE:-llm}"
SEED_DAYS="${SEED_DAYS:-7}"
BOB_WEEKLY_USD="${BOB_WEEKLY_USD:-12}"
TEAM_WEEKLY_USD="${TEAM_WEEKLY_USD:-25}"
KC_ISSUER="${KC_ISSUER:-https://keycloak.agentic.eu0.internal/realms/agentregistry}"
KC_JWKS="${KC_JWKS:-http://keycloak.keycloak.svc.cluster.local/realms/agentregistry/protocol/openid-connect/certs}"

ch() { kc -n "$CH_NS" exec -i "$CH_POD" -c clickhouse -- clickhouse-client "$@"; }

seed() {
  step "seed: ${SEED_DAYS} days of spend in platformdb.agw_spans_typed"
  local have
  have="$(ch -q "SELECT count() FROM platformdb.agw_spans_typed WHERE startsWith(TraceId, 'seed-')")"
  if [[ "$have" -gt 0 && "${SEED_FORCE:-0}" != 1 ]]; then
    ok "already seeded ($have rows); SEED_FORCE=1 adds another week on top"
    return
  fi
  python3 - "$SEED_DAYS" <<'EOF' | ch -q "INSERT INTO platformdb.agw_spans_typed FORMAT JSONEachRow"
import json, random, sys, uuid
from datetime import datetime, timedelta, timezone

random.seed()
days = int(sys.argv[1])
now = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=10)
start = now - timedelta(days=days)

# who: (team, calls on a busy weekday, agent mix)
people = {
    "bob":   ("payments-ops", 900, {"payments": .55, "credit": .25, "compliance": .10, "gdpr": .10}),
    "alice": ("compliance",   600, {"compliance": .50, "gdpr": .30, "payments": .10, "credit": .10}),
}
# model: (route, $ per 1M input, $ per 1M output, share of calls)
models = {
    "gemma-3-27b-it":   ("model/llm",                  0.60, 1.80, .85),
    "gemini-3.8-flash": ("agentgateway-system/models", 0.50, 3.00, .15),
}
# Agents carry tool schemas and history: big prompts, short answers. Payments
# and credit pull more account data into context than the policy agents.
prompt_size = {"payments": 3400, "credit": 4200, "compliance": 2600, "gdpr": 2200}

def pick(weights):
    return random.choices(list(weights), weights=list(weights.values()))[0]

t = start
while t < now:
    # Berlin office hours (UTC+2), weekdays heavy, weekends a trickle.
    hour_local = (t.hour + 2) % 24
    weekday = t.weekday() < 5
    busy = (1.0 if 8 <= hour_local < 18 else .08) * (1.0 if weekday else .15)
    for user, (team, per_day, mix) in people.items():
        calls = sum(1 for _ in range(int(per_day / 10 * 2)) if random.random() < busy * .5)
        for _ in range(calls):
            ts = t + timedelta(seconds=random.uniform(0, 3600))
            if ts >= now:
                continue
            domain = pick(mix)
            model = pick({m: v[3] for m, v in models.items()})
            route, pin, pout, _ = models[model]
            tin = max(200, int(random.gauss(prompt_size[domain], prompt_size[domain] * .25)))
            tout = max(20, int(random.lognormvariate(5.6, .6)))   # median ~270
            cost = round(tin * pin / 1e6 + tout * pout / 1e6, 9)
            dur = int((0.25 + tout / (55 if model.startswith("gemma") else 140)) * 1e9)
            print(json.dumps({
                "Timestamp": ts.strftime("%Y-%m-%d %H:%M:%S.%f"),
                "TraceId": "seed-" + uuid.uuid4().hex[:27],
                "SpanId": uuid.uuid4().hex[:16],
                "ParentSpanId": "",
                "ServiceName": "agentgateway-proxy",
                "SpanName": "POST /v1/chat/completions/*",
                "Duration": dur,
                "RequestModel": model, "ResponseModel": model, "Provider": "openai",
                "InputTokens": tin, "OutputTokens": tout,
                "Route": route, "HttpPath": "", "HttpStatus": 0,
                "MCPTarget": "", "MCPResourceName": "", "MCPResourceType": "", "ToolName": "",
                "ErrorMsg": "", "IsRoot": 1, "HasAttrs": 1,
                "CostUsd": cost, "CacheReadCostUsd": 0, "CacheWriteCostUsd": 0,
                "CustomDimensions": {"user": user, "group": team,
                                     "agent": f"trustusbank-{domain}",
                                     "model": model, "provider": "openai"},
                "Cluster": "agentic", "Namespace": "agentgateway-system",
            }))
    t += timedelta(hours=1)
EOF
  ok "$(ch -q "SELECT concat(toString(count()), ' rows, \$', toString(round(sum(CostUsd), 2))) FROM platformdb.agw_spans_typed WHERE startsWith(TraceId, 'seed-')")"
}

budget() {
  step "budget: bob \$${BOB_WEEKLY_USD}/week, payments-ops \$${TEAM_WEEKLY_USD}/week"
  kc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBudget
metadata:
  name: trustusbank
  namespace: $AGW_NS
  labels:
    company: trustusbank
spec:
  budgets:
  - name: bob-weekly
    subject:
      user: bob
    limit:
      amount: $BOB_WEEKLY_USD
      unit: USD
    window:
      unit: Week
    onBudgetExceeded: Block
  - name: payments-ops-weekly
    subject:
      group: payments-ops
    limit:
      amount: $TEAM_WEEKLY_USD
      unit: USD
    window:
      unit: Week
    onBudgetExceeded: Audit
EOF
}

# One policy per route: a policy must live in its target's namespace.
ROUTES=("$LLM_NS/$LLM_ROUTE" "$AGW_NS/models")

enforce() {
  local r ns name
  for r in "${ROUTES[@]}"; do
    ns="${r%/*}" name="${r#*/}"
    step "enforce: Permissive JWT + budget enforcement on $r"
    kc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ${name}-identity-budget
  namespace: $ns
  labels:
    company: trustusbank
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: $name
  traffic:
    # Permissive: a valid bearer is named in the dimensions; no bearer, or one
    # that is not a JWT (the agents' API key), still passes. Optional rejects
    # the agents' key as malformed; Strict would break every unsigned caller.
    jwtAuthentication:
      mode: Permissive
      providers:
      - issuer: $KC_ISSUER
        jwks:
          remote:
            url: $KC_JWKS
    entBudgetEnforcement:
      discovery:
        namespaces:
          from: All
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
  step "check"
  ch -q "SELECT dimension_id, dimension_value, countMerge(request_count) AS requests,
           round(toFloat64(sumMerge(spend_usd)), 2) AS usd
         FROM platformdb.agw_cost_dimensions_5m
         WHERE dimension_id IN ('user', 'group', 'agent') AND bucket > now() - INTERVAL $SEED_DAYS DAY
         GROUP BY dimension_id, dimension_value ORDER BY dimension_id, usd DESC FORMAT PrettyCompact" >&2
  kc -n "$AGW_NS" get enterpriseagentgatewaybudget trustusbank \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' >&2 || true
  local r
  for r in "${ROUTES[@]}"; do
    kc -n "${r%/*}" get enterpriseagentgatewaypolicy "${r#*/}-identity-budget" \
      -o jsonpath="{range .status.ancestors[*].conditions[*]}$r {.type}={.status} {.message}{'\n'}{end}" >&2 2>/dev/null || true
  done
  ok "Cost Management: https://kagent.${BASE_DOMAIN:-agentic.eu0.internal}/age/cost-management"
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
