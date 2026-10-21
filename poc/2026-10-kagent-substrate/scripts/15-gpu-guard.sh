#!/usr/bin/env bash
# 15-gpu-guard.sh — refuse GPU workloads on this cluster, and prove it.
#
# Deleting the old cluster removed its H100 node. This makes sure the new one
# cannot grow another: Autopilot provisions accelerator nodes on demand, so the
# guard is an admission policy (yaml/gpu-guard.yaml). The project's GPU quota is
# deliberately untouched; it took a Google support case to obtain.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl
assert_kube

step "ValidatingAdmissionPolicy deny-gpu-workloads"
kubectl apply -f "$LAB_ROOT/yaml/gpu-guard.yaml" >/dev/null
ok "applied"

NS=gpu-guard-probe
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
trap 'kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

probe() {  # probe NAME EXTRA_YAML — server dry-run of a pod
  kubectl -n "$NS" apply --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $1 }
spec:
  restartPolicy: Never
$2
  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      resources:
        requests: { cpu: 250m, memory: 512Mi }
$3
YAML
}

step "probes (server-side dry run: nothing is scheduled)"
# A well-formed Autopilot GPU pod, selector AND limit, the way the old Gemma
# Deployment asked for its H100. A malformed one could be refused by Warden for
# its shape, and that refusal would pass for this policy working.
SELECTOR="  nodeSelector: { cloud.google.com/gke-accelerator: nvidia-h100-80gb }"
LIMIT="        limits: { nvidia.com/gpu: \"1\" }"
# Policies take a few seconds to reach every API server replica.
for _ in $(seq 1 12); do
  OUT="$(probe gpu-h100 "$SELECTOR" "$LIMIT" || true)"
  grep -q "GPU access is disabled" <<<"$OUT" && break
  sleep 5
done
grep -q "GPU access is disabled" <<<"$OUT" \
  && ok "H100 pod (accelerator selector + nvidia.com/gpu) is refused" \
  || die "GPU pod was NOT refused: $OUT"

OUT="$(kubectl -n "$NS" create deployment gpu-deploy --image=registry.k8s.io/pause:3.10 \
  --dry-run=client -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
spec = d["spec"]["template"]["spec"]
spec["nodeSelector"] = {"cloud.google.com/gke-accelerator": "nvidia-h100-80gb"}
spec["containers"][0]["resources"] = {"limits": {"nvidia.com/gpu": "1"}}
print(json.dumps(d))' | kubectl apply --dry-run=server -f - 2>&1 || true)"
grep -q "GPU access is disabled" <<<"$OUT" \
  && ok "GPU Deployment is refused at apply time" \
  || die "GPU Deployment was NOT refused: $OUT"

OUT="$(probe cpu-only "" "" || true)"
grep -q "created (server dry run)" <<<"$OUT" \
  && ok "CPU-only pod is still admitted" \
  || die "the policy refused an ordinary pod: $OUT"
