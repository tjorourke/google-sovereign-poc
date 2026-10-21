#!/usr/bin/env bash
# 30-agentgateway.sh — Solo Enterprise for agentgateway (latest), with an
# OpenAI route the agents use instead of a GPU-hosted model.
#
# Standalone gateway only: no Istio on this cluster, so no waypoint classes,
# no Istio identity parameters, no ambient labels.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl helm curl
assert_kube
load_secrets
: "${AGENTGATEWAY_LICENSE_KEY:?AGENTGATEWAY_LICENSE_KEY missing from the secrets file}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY missing from the secrets file}"

NS=agentgateway-system

step "Gateway API standard CRDs $GATEWAY_API_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "installed"

step "enterprise-agentgateway $AGW_ENT_VERSION"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install enterprise-agentgateway-crds "$AGW_CHART_BASE/enterprise-agentgateway-crds" \
  -n "$NS" --version "$AGW_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "CRDs"
helm upgrade --install enterprise-agentgateway "$AGW_CHART_BASE/enterprise-agentgateway" \
  -n "$NS" --version "$AGW_ENT_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 10m >/dev/null
ok "controller $(kubectl -n "$NS" get deploy enterprise-agentgateway -o jsonpath='{.spec.template.spec.containers[0].image}')"
wait_until 120 "GatewayClass enterprise-agentgateway accepted" \
  sh -c "kubectl get gatewayclass enterprise-agentgateway -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' | grep -q True"

step "OpenAI credential (held by the gateway only)"
# agentgateway sends the Secret's Authorization value upstream verbatim.
kubectl -n "$NS" create secret generic openai-secret \
  --from-literal=Authorization="Bearer $OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "openai-secret"

step "Gateway, OpenAI backend and route"
sed "s/__OPENAI_MODEL__/$OPENAI_MODEL/" "$LAB_ROOT/yaml/agentgateway.yaml" | kubectl apply -f - >/dev/null
wait_until 300 "Gateway agentgateway-proxy programmed" \
  sh -c "kubectl -n $NS get gateway agentgateway-proxy -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
wait_until 300 "proxy Deployment available" \
  kubectl -n "$NS" wait deploy/agentgateway-proxy --for=condition=Available --timeout=10s

step "a chat completion through the gateway, from inside the cluster"
# A placeholder key on purpose: the request only works if the gateway injects
# the real one.
POD=agw-probe
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.16.0
      resources:
        requests: { cpu: 250m, memory: 512Mi }
      env:
        - name: BODY
          value: '{"model":"$OPENAI_MODEL","messages":[{"role":"user","content":"Reply with exactly: agentgateway ok"}]}'
      command: ["sh", "-c"]
      args:
        - |
          curl -s -m 60 -w '\nHTTP %{http_code}\n' \
            -H 'Authorization: Bearer placeholder-not-a-key' \
            -H 'Content-Type: application/json' -d "\$BODY" \
            http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/chat/completions
YAML
kubectl -n "$NS" wait pod/"$POD" --for=jsonpath='{.status.phase}'=Succeeded --timeout=240s >/dev/null 2>&1 || true
OUT="$(kubectl -n "$NS" logs "$POD" 2>&1 || true)"
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
printf '%s\n' "$OUT" | tail -3 | cut -c1-300 | sed 's/^/    /'
grep -q "HTTP 200" <<<"$OUT" && grep -qi "agentgateway ok" <<<"$OUT" \
  && ok "agentgateway -> OpenAI works, and the client never held the key" \
  || die "chat completion through agentgateway failed"
