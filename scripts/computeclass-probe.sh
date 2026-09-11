#!/usr/bin/env bash
# computeclass-probe.sh — is ComputeClass served, and can a GPU pod schedule?
#
# Written to answer Google's question of 2026-09-11 reproducibly: their engineer
# reproduced our missing-CRD failure on 1.35.6 and reported success on a 1.36
# Rapid cluster. This runs the identical checks on whatever cluster is current,
# so the two results differ only by GKE version.
#
#   ./scripts/computeclass-probe.sh            # checks + GPU scheduling test
#   ./scripts/computeclass-probe.sh --no-gpu   # CRD checks only, no pods
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${GCD_KUBECONFIG:-$REPO/poc/2026-09-agentic-platform/deploy/.kubeconfig}"
[[ -f "$REPO/.env.local" ]] && { set -a; source "$REPO/.env.local"; set +a; }
export GOOGLE_CLOUD_UNIVERSE_DOMAIN="${UNIVERSE_API_DOMAIN:-}"
GPU=1; [[ "${1:-}" == "--no-gpu" ]] && GPU=0
hdr(){ printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){  printf '  \033[31m✗\033[0m %s\n' "$*"; }

timeout 25 kubectl version --request-timeout=10s >/dev/null 2>&1 \
  || { echo "cannot reach the cluster; re-authenticate first" >&2; exit 75; }

hdr "Cluster under test"
gcloud container clusters list \
  --format='table(name,location,status,currentMasterVersion,releaseChannel.channel,autopilot.enabled)' 2>&1

hdr "1. Is the ComputeClass CRD served?"
echo "\$ kubectl api-resources --api-group=cloud.google.com"
kubectl api-resources --api-group=cloud.google.com 2>&1
echo
echo "\$ kubectl get crd | grep -i computeclass"
kubectl get crd 2>/dev/null | grep -i computeclass || echo "(no matches)"
echo
echo "\$ kubectl explain computeclass"
kubectl explain computeclass 2>&1 | head -2
if kubectl get crd 2>/dev/null | grep -qi computeclass; then
  ok "ComputeClass CRD IS served"
  CC=1
else
  no "ComputeClass CRD is NOT served"
  CC=0
fi

[[ "$GPU" -eq 1 ]] || { echo; exit 0; }

hdr "2. Path 1 — gke-accelerator with an accelerator type (needs no CRD)"
kubectl -n default delete pod gpu-probe --ignore-not-found --wait=false >/dev/null 2>&1
cat <<YAML | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: gpu-probe, namespace: default }
spec:
  restartPolicy: Never
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-h100-80gb
  containers:
    - name: probe
      image: nginx:stable
      resources:
        limits: { nvidia.com/gpu: "1" }
        requests: { cpu: "1", memory: 2Gi }
YAML
echo "  waiting up to 5 minutes for a GPU node..."
for _ in $(seq 1 30); do
  P="$(kubectl -n default get pod gpu-probe -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "$P" == "Running" || "$P" == "Succeeded" ]] && break
  sleep 10
done
kubectl -n default get pod gpu-probe -o wide --no-headers 2>&1 | sed 's/^/  /'
kubectl -n default describe pod gpu-probe 2>/dev/null | sed -n '/Events:/,$p'
[[ "$(kubectl -n default get pod gpu-probe -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]] \
  && ok "GPU pod SCHEDULED — a node was provisioned" \
  || no "GPU pod did not schedule"

if [[ "$CC" -eq 1 ]]; then
  hdr "3. Path 2 — a custom ComputeClass with a GPU priority rule"
  cat <<'YAML' | kubectl apply -f - 2>&1 | sed 's/^/  /'
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: h100-class
spec:
  priorities:
    - machineFamily: a3
      gpu:
        type: nvidia-h100-80gb
        count: 8
  nodePoolAutoCreation:
    enabled: true
  whenUnsatisfiable: DoNotScaleUp
YAML
  kubectl get computeclass h100-class -o yaml 2>&1 | head -20 | sed 's/^/  /'
fi

hdr "Cleanup"
kubectl -n default delete pod gpu-probe --ignore-not-found --wait=false >/dev/null 2>&1 && echo "  probe pod removed"
