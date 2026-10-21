#!/usr/bin/env bash
# 50-agents.sh — deploy the test agents and sandbox template (yaml/agents.yaml)
# and wait until Substrate has prepared them.
#
# "Ready" for an Agent means its revision compiled to a Substrate ActorTemplate,
# a golden actor booted on a gVisor worker, and its snapshot was stored. Every
# conversation afterwards is an actor restored from that snapshot.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl
assert_kube

kubectl -n kagent get workerpool kagent-default >/dev/null 2>&1 \
  || die "no WorkerPool kagent/kagent-default; run 40-kagent.sh first"

step "Harness, Agents and SandboxTemplate"
kubectl apply -f "$LAB_ROOT/yaml/agents.yaml" | sed 's/^/    /'

ready() {  # ready KIND NAME
  [[ "$(kubectl -n kagent get "$1" "$2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

step "waiting for Substrate to prepare each revision (golden actor + snapshot)"
rc=0
for a in agent/trustusbank-assistant agent/trustusbank-sandbox-ops sandboxtemplate/trustusbank-scratch; do
  if ! wait_until 900 "$a Ready" ready "${a%%/*}" "${a#*/}"; then
    rc=1
    kubectl -n kagent get "$a" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1 | sed 's/^/    /' >&2
  fi
done

step "status"
kubectl -n kagent get harness,agent,sandboxtemplate 2>&1 | sed 's/^/    /'
exit "$rc"
