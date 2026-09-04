#!/usr/bin/env bash
# 60-model.sh — self-hosted, in-universe LLM inference.
#
# GCD has NO aiplatform: no Vertex, no Gemini, no managed model endpoint of any
# kind. Google's own GCD reference architectures (/docs/gcd-solutions/) answer
# that by self-hosting open-weight Gemma on GKE, so that is what we do — with
# one difference that is the entire point of this repo: the model sits behind
# agentgateway, so prompts and tokens are policy-checked and audited. Google's
# blueprints call Gemma directly with nothing in the path.
#
# Two profiles:
#   MODEL_PROFILE=gpu   gemma-3-27b-it on a3-highgpu-8g-nolssd (H100 80GB x8),
#                       Accelerator compute class. Needs GPU quota, which a
#                       preview project almost certainly does not have — and in
#                       GCD a quota increase can ONLY be requested through GCD
#                       support, which needs the public GCP org + Assured
#                       Workloads folder + up to 48 business hours.
#   MODEL_PROFILE=cpu   a small Gemma on C3. Google's own Compute differences
#                       page says "Consider doing CPU inferencing if A3 High or
#                       A3 Edge is too large for your workload", so this is
#                       their advice, not a fudge. Poor model, fine demo: the
#                       agent gets a real in-universe endpoint with no egress.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl
load_env
assert_universe

NS="${MODEL_NS:-model}"
PROFILE="${MODEL_PROFILE:-auto}"
WEIGHTS_BUCKET="${WEIGHTS_BUCKET:-$( cd "$TOFU_DIR" && tofu output -json buckets 2>/dev/null | jq -r '.weights // empty' )}"

# ── quota check decides the profile ─────────────────────────────────────────
if [[ "$PROFILE" == "auto" ]]; then
  step "checking GPU quota in $UNIVERSE_REGION (probe 0.10)"
  GPU_LIMIT="$(gcloud compute regions describe "$UNIVERSE_REGION" --project "$PROJECT_ID" \
    --format='value(quotas.filter("metric:NVIDIA_H100_GPUS").limit)' 2>/dev/null || true)"
  [[ -z "$GPU_LIMIT" ]] && GPU_LIMIT="$(gcloud compute regions describe "$UNIVERSE_REGION" \
    --project "$PROJECT_ID" --format=json 2>/dev/null \
    | jq -r '[.quotas[] | select(.metric|test("GPU"))] | max_by(.limit) | .limit // 0' 2>/dev/null || echo 0)"
  GPU_LIMIT="${GPU_LIMIT:-0}"
  log "largest GPU quota limit: $GPU_LIMIT"
  if (( $(printf '%.0f' "$GPU_LIMIT" 2>/dev/null || echo 0) >= 8 )); then
    PROFILE=gpu; ok "GPU quota available — using the A3/H100 profile"
  else
    PROFILE=cpu
    warn "no usable GPU quota. Falling back to CPU inference on C3."
    warn "To fix it: quota increases in GCD go ONLY through GCD support, which"
    warn "needs a public GCP org + an Assured Workloads folder + an empty"
    warn "support project, then up to 48 business hours. Stand that up this week."
  fi
fi

case "$PROFILE" in
  gpu)
    MODEL_ID="${MODEL_ID:-google/gemma-3-27b-it}"
    COMPUTE_CLASS_ANN='cloud.google.com/compute-class: "Accelerator"'
    GPU_ANN='cloud.google.com/gke-accelerator: "nvidia-h100-80gb"'
    GPU_COUNT_ANN='cloud.google.com/gke-accelerator-count: "8"'
    RESOURCES='requests: { cpu: "8", memory: 64Gi, nvidia.com/gpu: 8 }
            limits:   { cpu: "16", memory: 128Gi, nvidia.com/gpu: 8 }'
    EXTRA_ARGS='--tensor-parallel-size=8'
    ;;
  cpu)
    MODEL_ID="${MODEL_ID:-google/gemma-3-1b-it}"
    COMPUTE_CLASS_ANN='cloud.google.com/compute-class: "general-purpose"'
    GPU_ANN=''
    GPU_COUNT_ANN=''
    RESOURCES='requests: { cpu: "8", memory: 16Gi }
            limits:   { cpu: "16", memory: 32Gi }'
    EXTRA_ARGS='--device=cpu --dtype=float32'
    ;;
  *) die "MODEL_PROFILE must be gpu, cpu or auto" ;;
esac

ok "profile=$PROFILE model=$MODEL_ID"

# ── weights ─────────────────────────────────────────────────────────────────
# Gemma is a gated repo on Hugging Face, so pulling weights needs a token — a
# secret, in a universe with no Secret Manager. Envelope-encrypt it.
if [[ -z "${HF_TOKEN:-}" ]]; then
  warn "HF_TOKEN not set. Gemma weights are gated on Hugging Face, so vLLM cannot"
  warn "download them. Two options:"
  warn "  a) export HF_TOKEN=<token> and re-run (needs pod egress — probe 0.2)"
  warn "  b) stage the weights into gs://${WEIGHTS_BUCKET:-<bucket>} and mount them"
  warn "     with the Cloud Storage FUSE CSI driver (GKE 1.36.0-gke.1266000+,"
  warn "     with skipCSIBucketAccessCheck: \"true\")"
  die "no weights source"
fi

step "namespace + HF token (envelope-encrypted where possible)"
kc create ns "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$NS" create secret generic hf-token --from-literal=token="$HF_TOKEN" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
warn "note: this Secret is PLAINTEXT in etcd. GKE on GCD does not support"
warn "application-layer Secret encryption, and there is no Secret Manager to"
warn "move it to. That is a real gap, not a solved problem — say so."

step "vLLM ($PROFILE)"
kc -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  labels: { app: vllm }
spec:
  replicas: 1
  selector: { matchLabels: { app: vllm } }
  template:
    metadata:
      labels: { app: vllm }
      annotations:
        ${COMPUTE_CLASS_ANN}
        ${GPU_ANN}
        ${GPU_COUNT_ANN}
    spec:
      serviceAccountName: default
      containers:
        - name: vllm
          image: ${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}
          args:
            - --model=${MODEL_ID}
            - --served-model-name=${MODEL_ID##*/}
            - --host=0.0.0.0
            - --port=8000
            - --max-model-len=8192
            - ${EXTRA_ARGS}
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom: { secretKeyRef: { name: hf-token, key: token } }
          ports: [{ containerPort: 8000, name: http }]
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 60
          resources:
            ${RESOURCES}
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
spec:
  selector: { app: vllm }
  ports: [{ name: http, port: 8000, targetPort: 8000 }]
YAML
ok "vLLM applied"

step "waiting for the model to load (this takes a while — weights download)"
kc -n "$NS" rollout status deploy/vllm --timeout=1800s || {
  warn "vLLM did not become ready. Check:"
  warn "  kubectl --context $(kube_context) -n $NS logs deploy/vllm --tail=60"
  warn "  kubectl --context $(kube_context) -n $NS get events --sort-by=.lastTimestamp | tail"
  warn "If it is Pending on GPU, that is probe 0.10 answering no — record it."
  die "model not ready"
}
ok "model serving on vllm.${NS}.svc.cluster.local:8000"

# ── put agentgateway in front of it. This is the whole point. ──────────────
step "agentgateway LLM backend + route"
kc -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: gemma
spec:
  ai:
    llm:
      openai:
        model: ${MODEL_ID##*/}
    host:
      host: vllm.${NS}.svc.cluster.local
      port: 8000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gemma
spec:
  parentRefs: [{ name: agentgateway-proxy, namespace: agentgateway-system }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /v1 } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: gemma
YAML
ok "agentgateway fronting the model"

cat >&2 <<EOF

  In-universe inference, no egress, no managed model service, and every request
  through a policy point:

    model     ${MODEL_ID}  (profile: ${PROFILE})
    direct    vllm.${NS}.svc.cluster.local:8000/v1   (do not point agents here)
    gateway   http://agentgateway-proxy.agentgateway-system:80/v1

  Point kagent at the gateway:
    MODEL_PROVIDER=selfhosted ./scripts/40-kagent.sh

  This is the difference between our template and Google's two GCD blueprints:
  theirs call Gemma directly with nothing in the path — no LLM traffic
  management, no per-tool authorization, no audit of agent-to-model flows.
EOF
