#!/usr/bin/env bash
# 60-model.sh — self-hosted model inside the sovereign boundary.
#
# GCD has no aiplatform, so there is no managed inference of any kind. The only
# in-universe path is to host the model yourself, which is also what Google's own
# GCD reference architectures do.
#
# TWO PROFILES, and the default is the one that actually works here:
#
#   cpu (default)  llama.cpp serving a 4-bit GGUF on general-purpose C3.
#                  Qwen2.5-3B-Instruct, chosen because it is UNGATED on Hugging
#                  Face. Gemma and Llama both need an access token, and GCD has
#                  no Secret Manager to hold one.
#
#   gpu            vLLM serving Gemma 3 27B IT on A3/H100, which is what Google's
#                  blueprints assume. CURRENTLY IMPOSSIBLE in Berlin: the H100 is
#                  catalogued but no GPU node ever provisions, and the autoscaler
#                  reports a node affinity mismatch rather than a quota error.
#                  See feedback/google/06. Kept here so the switch is one
#                  variable once Google unblocks it.
#
# Two earlier attempts that failed, recorded so nobody repeats them:
#   - vLLM on CPU. The standard vllm-openai image is CUDA-only; it cannot run
#     without a GPU at all, so it is not a fallback.
#   - Qwen2.5-0.5B. Too weak for tool calling: it emitted `reverse_text("` as
#     literal text instead of calling the tool. 3B is the smallest that reliably
#     drives MCP.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

NS="${MODEL_NS:-model}"
# Same default as 80-ingress.sh and 90-mcp-agent.sh.
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
PROFILE="${MODEL_PROFILE:-cpu}"
require kubectl

case "$PROFILE" in
  cpu)
    MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-3B-Instruct-GGUF:Q4_K_M}"
    SERVED_NAME="${SERVED_NAME:-Qwen2.5-3B-Instruct}"
    IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
    ;;
  gpu)
    MODEL_ID="${MODEL_ID:-google/gemma-3-27b-it}"
    SERVED_NAME="${SERVED_NAME:-gemma-3-27b-it}"
    IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}"
    warn "MODEL_PROFILE=gpu. In Berlin this WILL stay Pending: the H100 is"
    warn "catalogued but no GPU node provisions. See feedback/google/06."
    ;;
  *) die "MODEL_PROFILE must be cpu or gpu" ;;
esac
ok "profile=$PROFILE model=$MODEL_ID served as $SERVED_NAME"

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
# Enrol at creation, so the model is inside the mesh from its first breath and an
# ALLOW policy on it can identify the gateway. Harmless if ambient is absent.
kubectl label ns "$NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1

if [[ "$PROFILE" == "cpu" ]]; then
  step "llama.cpp serving $SERVED_NAME on CPU"
  # ephemeral-storage is the trap here. llama.cpp downloads the GGUF to local
  # disk at start-up, roughly 2 GB for a 3B model at Q4_K_M. Autopilot defaults
  # a pod to 1Gi and EVICTS on overrun, which looks like a crash with restarts=0
  # because eviction recreates the pod. The Autopilot maximum is 10Gi, so 9Gi is
  # the safe ceiling; asking for more is rejected outright.
  kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: ${NS}
  labels: { app: llm }
spec:
  replicas: 1
  selector: { matchLabels: { app: llm } }
  template:
    metadata: { labels: { app: llm } }
    spec:
      containers:
        - name: server
          image: ${IMAGE}
          args:
            - -hf
            - ${MODEL_ID}
            - --alias
            - ${SERVED_NAME}
            - --host
            - 0.0.0.0
            - --port
            - "8080"
            - -c
            - "4096"
            - --jinja
          ports: [{ containerPort: 8080, name: http }]
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 90
          resources:
            requests:
              cpu: "2"
              memory: 6Gi
              ephemeral-storage: 9Gi
            limits:
              cpu: "3"
              memory: 8Gi
              ephemeral-storage: 9Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llm
  namespace: ${NS}
  labels: { app: llm }
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: 8080, appProtocol: http }]
YAML
else
  step "vLLM serving $SERVED_NAME on A3/H100"
  [[ -n "${HF_TOKEN:-}" ]] || die "MODEL_PROFILE=gpu needs HF_TOKEN: Gemma is gated."
  kubectl -n "$NS" create secret generic hf-token \
    --from-literal=token="$HF_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: ${NS}
  labels: { app: llm }
spec:
  replicas: 1
  selector: { matchLabels: { app: llm } }
  template:
    metadata: { labels: { app: llm } }
    spec:
      nodeSelector:
        cloud.google.com/compute-class: Accelerator
        cloud.google.com/gke-accelerator: nvidia-h100-80gb
      containers:
        - name: server
          image: ${IMAGE}
          args:
            - --model=${MODEL_ID}
            - --served-model-name=${SERVED_NAME}
          ports: [{ containerPort: 8000, name: http }]
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom: { secretKeyRef: { name: hf-token, key: token } }
          resources:
            limits:
              nvidia.com/gpu: 8
              cpu: "8"
              memory: 32Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llm
  namespace: ${NS}
  labels: { app: llm }
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: 8000, appProtocol: http }]
YAML
fi

step "Waiting for the model to serve"
# A cold start downloads the weights, so this is minutes not seconds.
if kubectl -n "$NS" rollout status deploy/llm --timeout=900s >/dev/null 2>&1; then
  ok "llm is ready"
else
  warn "llm did not become ready. Recent events:"
  kubectl -n "$NS" describe deploy llm 2>/dev/null | sed -n '/Events:/,$p' | tail -5 | sed 's/^/    /' >&2
  kubectl -n "$NS" logs deploy/llm --tail=15 2>/dev/null | sed 's/^/    /' >&2
  die "model not serving"
fi

step "Confirming the OpenAI-compatible API"
kubectl -n "$NS" run model-probe --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.11.0 --command -- \
  curl -sS -m 30 "http://llm.${NS}.svc.cluster.local:8080/v1/models" 2>/dev/null \
  | head -c 300 | sed 's/^/    /' >&2 || warn "could not query /v1/models"
echo >&2

# ── put agentgateway in front of it ──────────────────────────────────────────
# This used to be left to 80-ingress.sh, which never did it: its host list is
# keycloak/agentregistry/kagent, and it runs BEFORE this phase, so the model
# namespace does not exist yet. The result was that llm.${BASE_DOMAIN} had
# neither a route nor a DNS record, while kagent's ModelConfig and the
# AgentRegistry Deployment env both pointed at it -- every agent call died on a
# connection timeout to an address nothing served.
step "Fronting the model with agentgateway at llm.${BASE_DOMAIN}"
GW_LB="$(kubectl -n agentgateway-system get svc agentgateway-proxy \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -n "$GW_LB" ]]; then
  sed "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" "$LAB_ROOT/model/llm-route.yaml" \
    | kubectl apply -f - >/dev/null \
    && ok "HTTPRoute llm.${BASE_DOMAIN} -> llm:8080" \
    || warn "could not apply the llm HTTPRoute"
  dns_upsert "llm.${BASE_DOMAIN}" "$GW_LB"
else
  warn "agentgateway has no LB address; skipping the llm route and DNS record."
  warn "Run 70-agentgateway.sh and 80-ingress.sh, then re-run this phase."
fi

# ── the ModelConfig declarative agents resolve ───────────────────────────────
# Must come from here, not from 40-kagent.sh: only this phase knows what
# llama.cpp is actually serving, and the chart cannot express the endpoint at
# all (see model/modelconfig-selfhosted.yaml).
step "ModelConfig/selfhosted -> ${SERVED_NAME} via agentgateway"
sed -e "s|__KAGENT_NS__|${KAGENT_NS:-kagent}|g" \
    -e "s|__SERVED_NAME__|${SERVED_NAME}|g" \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    "$LAB_ROOT/model/modelconfig-selfhosted.yaml" \
  | kubectl apply -f - >/dev/null \
  && ok "ModelConfig/selfhosted in ${KAGENT_NS:-kagent}" \
  || warn "could not apply ModelConfig/selfhosted"

# The chart-generated default carries the chart's guess at a model name and no
# endpoint. Point it at the same place so nothing silently inherits a model the
# server does not serve.
kubectl -n "${KAGENT_NS:-kagent}" patch modelconfig default-model-config --type=merge \
  -p "{\"spec\":{\"model\":\"${SERVED_NAME}\",\"openAI\":{\"baseUrl\":\"http://llm.${BASE_DOMAIN}/v1\"}}}" >/dev/null 2>&1 \
  && ok "default-model-config re-pointed at ${SERVED_NAME}" \
  || warn "could not patch default-model-config (is 40-kagent.sh done?)"

cat >&2 <<EOF

  Model:  ${SERVED_NAME}  (profile: ${PROFILE})
  In-cluster: http://llm.${NS}.svc.cluster.local:8080/v1
  Via agentgateway: http://llm.${BASE_DOMAIN}/v1

  Nothing leaves the sovereign boundary: the weights are pulled once at start-up
  and inference is local. agentgateway fronts it at the address above, which is
  the URL kagent's ModelConfig and the AgentRegistry Deployment env point at.

  Next: ./scripts/70-agentgateway.sh, then ./scripts/90-mcp-agent.sh
EOF
