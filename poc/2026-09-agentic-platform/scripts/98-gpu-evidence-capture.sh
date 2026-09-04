#!/usr/bin/env bash
# capture.sh — collects the live evidence for the GCD Berlin GPU support case.
# Re-runnable. Applies the four probe manifests, waits for the autoscaler to
# make its decision, records everything, then cleans the probe pods up.
#
# Requires an active GCD session:
#   cd ~/code/google-sov && ./scripts/gcd-auth.sh
#   gcloud container clusters get-credentials agentic \
#     --location u-germany-northeast1 --project 'eu0:soloio-eval'
set -uo pipefail
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$OUT/output"
mkdir -p "$O"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PODS="gpu-v1-accelerator-8 gpu-v2-accelerator-1 gpu-v3-inferred gpu-v4-machine-family"

say() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*" >&2; }

kubectl version --request-timeout=10s >/dev/null 2>&1 || {
  printf '\033[1;31m✗ cannot reach the cluster — re-run ./scripts/gcd-auth.sh first\033[0m\n' >&2
  exit 1
}

say "1/7 cluster and universe facts"
{
  echo "# Captured $TS"
  echo
  echo '$ gcloud config list'
  gcloud config list 2>&1
  echo
  echo '$ gcloud container clusters describe agentic --location u-germany-northeast1'
  gcloud container clusters describe agentic --location u-germany-northeast1 \
    --format='yaml(name,location,currentMasterVersion,currentNodeVersion,releaseChannel,autopilot,nodeConfig.machineType,locations,status)' 2>&1
  echo
  echo '$ kubectl version'
  kubectl version 2>&1
} > "$O/01-cluster.txt" 2>&1

say "2/7 accelerator and machine type catalogue"
{
  echo "# Captured $TS"
  echo
  echo '$ gcloud compute accelerator-types list'
  gcloud compute accelerator-types list 2>&1
  echo
  echo '$ gcloud compute machine-types list --filter="name~a3"'
  gcloud compute machine-types list --filter="name~a3" 2>&1
  echo
  echo '# NOTE: nvidia-h100-80gb appears in zones -a and -b only, not -c.'
} > "$O/02-catalogue.txt" 2>&1

say "3/7 quota metrics (full dump plus the GPU-relevant subset)"
{
  echo "# Captured $TS"
  echo
  echo '$ gcloud compute project-info describe  --- GPU / A3 relevant metrics'
  gcloud compute project-info describe --format=json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ms=[q['metric'] for q in d.get('quotas',[])]
print('  NVIDIA_H100_80GB_GPUS present :', 'NVIDIA_H100_80GB_GPUS' in ms)
print('  A3_CPUS present               :', 'A3_CPUS' in ms)
print('  metrics containing H100       :', [m for m in ms if 'H100' in m] or 'NONE')
print('  metrics starting A3           :', [m for m in ms if m.startswith('A3')] or 'NONE')
print()
print('  All GPU-ish metrics offered on this project:')
for q in sorted(d.get('quotas',[]), key=lambda x: x['metric']):
    if 'GPU' in q['metric']:
        print('    %-30s limit=%s usage=%s' % (q['metric'], q['limit'], q['usage']))
print()
print('  Full metric list follows.')
for q in sorted(d.get('quotas',[]), key=lambda x: x['metric']):
    print('    %-30s limit=%s usage=%s' % (q['metric'], q['limit'], q['usage']))
" 2>&1
} > "$O/03-quota.txt" 2>&1

say "4/7 existing nodes and available compute classes"
{
  echo "# Captured $TS"
  echo
  echo '$ kubectl get nodes -o wide'
  kubectl get nodes -o wide 2>&1
  echo
  echo '# Node labels relevant to accelerator scheduling:'
  kubectl get nodes -o json 2>/dev/null | python3 -c "
import json,sys
for n in json.load(sys.stdin).get('items',[]):
    l=n['metadata']['labels']
    print(' ', n['metadata']['name'])
    for k in sorted(l):
        if any(t in k for t in ('accelerator','compute-class','machine-family','machine-type','zone','instance-type')):
            print('     %-52s %s' % (k, l[k]))
" 2>&1
  echo
  echo '$ kubectl get computeclasses -A       (custom ComputeClass objects, if any)'
  kubectl get computeclasses -A 2>&1
  echo
  echo '$ kubectl get nodes -o jsonpath   allocatable nvidia.com/gpu per node'
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>&1
} > "$O/04-nodes.txt" 2>&1

say "5/7 applying the four probe manifests (capturing admission results verbatim)"
kubectl delete pod $PODS --ignore-not-found >/dev/null 2>&1
{
  echo "# Captured $TS"
  echo "# Each manifest applied on its own so the admission result is attributable."
  for f in "$OUT"/manifests/gpu-probe-*.yaml; do
    echo
    echo "=============================================================="
    echo "\$ kubectl apply -f $(basename "$f")"
    echo "=============================================================="
    kubectl apply -f "$f" 2>&1
  done
} > "$O/05-apply.txt" 2>&1

say "6/7 waiting 5 minutes for the cluster autoscaler to decide"
for i in $(seq 1 10); do
  printf '    %ds\n' $((i*30)) >&2
  sleep 30
done

say "7/7 pod state, events, describe and log attempts"
{
  echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ), 5 minutes after apply"
  echo
  echo '$ kubectl get pods -o wide'
  kubectl get pods -o wide 2>&1
  echo
  for p in $PODS; do
    echo
    echo "=============================================================="
    echo "POD: $p"
    echo "=============================================================="
    if ! kubectl get pod "$p" >/dev/null 2>&1; then
      echo "  (not created — rejected at admission; see 05-apply.txt)"
      continue
    fi
    echo
    echo "\$ kubectl describe pod $p"
    kubectl describe pod "$p" 2>&1
    echo
    echo "\$ kubectl logs $p"
    kubectl logs "$p" 2>&1
    echo "  ^ NOTE: no container logs exist because the pod never scheduled onto"
    echo "    a node. The failure is at provisioning, not inside the container."
  done
  echo
  echo '$ kubectl get events --sort-by=.lastTimestamp   (default namespace)'
  kubectl get events --sort-by=.lastTimestamp 2>&1 | tail -40
} > "$O/06-pods.txt" 2>&1

say "cleaning up probe pods"
kubectl delete pod $PODS --ignore-not-found >/dev/null 2>&1

printf '\n\033[32m✓ capture complete\033[0m\n' >&2
ls -la "$O" >&2
