#!/usr/bin/env bash
# 40-kagent.sh — kagent 1.0 on Agent Substrate, installed the way the kagent
# docs prescribe (`kagent install`), with this lab's values.
#
# `kagent install` installs, in order: kagent CRDs, Substrate CRDs, Substrate's
# certificate authorities and API authentication config, the Pod Certificate
# controller, a development PostgreSQL (shared by kagent and Substrate, logins
# by Pod Certificate rather than password), Substrate itself in ate-system,
# and kagent with a gVisor WorkerPool. Every agent then runs as a Substrate
# actor in a gVisor sandbox on that pool.
#
# Order matters on Autopilot:
#   1. 20-allowlists.sh atelet   BEFORE this: the substrate release waits for
#                                the atelet DaemonSet, which Warden refuses
#                                without its allowlist
#   2. this script
#   3. 20-allowlists.sh worker   AFTER this (run automatically below): the worker
#                                Deployment only exists once kagent creates its
#                                WorkerPool, and is refused until allowlisted
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl helm
assert_session
assert_kube

kubectl get workloadallowlist "substrate-atelet-${SUBSTRATE_VERSION}" >/dev/null 2>&1 \
  || die "the atelet allowlist is not installed; run: $LAB_ROOT/scripts/20-allowlists.sh atelet"

KAGENT="$(kagent_cli)"
ok "kagent CLI $("$KAGENT" version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["kagent_version"])')"

# `kagent install` asks for a 500Mi PostgreSQL volume; Hyperdisk Balanced, the
# only disk type in GCD, starts at 4 GiB, so the claim never provisions and the
# install times out. The policy raises claims to the floor (yaml/pvc-floor.yaml).
step "PVC floor for Hyperdisk Balanced"
kubectl apply -f "$LAB_ROOT/yaml/pvc-floor.yaml" >/dev/null 2>&1 || die "could not apply yaml/pvc-floor.yaml"
ok "MutatingAdmissionPolicy hyperdisk-pvc-floor"

step "kagent install ($KAGENT_VERSION, Substrate $SUBSTRATE_VERSION)"
# The real OpenAI key lives only in agentgateway (30-agentgateway.sh). kagent's
# default ModelConfig points there (yaml/kagent-values.yaml), so its Secret gets
# a placeholder. Helm waits up to 5 minutes per release, and a fresh Autopilot
# cluster can spend most of that provisioning nodes, so allow one retry: every
# step is an idempotent upgrade --install.
for attempt in 1 2; do
  if OPENAI_API_KEY="placeholder-the-key-is-in-agentgateway" \
      "$KAGENT" --config "$LAB_ROOT/yaml/kagent-cli-config.yaml" install --namespace kagent; then
    ok "kagent install (attempt $attempt)"
    break
  fi
  [[ "$attempt" -eq 2 ]] && die "kagent install failed twice; see the output above"
  warn "kagent install attempt $attempt failed; retrying (releases are idempotent)"
  sleep 20
done

step "Substrate and kagent control plane"
kubectl -n ate-system get deploy,ds -o wide 2>&1 | sed 's/^/    /'
kubectl -n kagent get deploy 2>&1 | sed 's/^/    /'

# yaml/substrate-values.yaml makes system:serviceaccount:ate-system:ate-operator
# a Substrate bootstrap owner (kagent's install names only its controller), so
# `kubectl ate --token-file` works for an operator. This is that account.
step "Substrate operator principal for kubectl ate"
kubectl apply -f "$LAB_ROOT/yaml/ate-operator.yaml" >/dev/null || die "could not apply yaml/ate-operator.yaml"
ok "ServiceAccount ate-system/ate-operator"

step "gVisor workers"
"$LAB_ROOT/scripts/20-allowlists.sh" worker
# A WorkerPool reports readyReplicas/replicas and a per-sandbox-class Resolved
# condition, not a Ready condition.
pool_ready() {
  local ready want resolved
  ready="$(kubectl -n kagent get workerpool kagent-default -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  want="$(kubectl -n kagent get workerpool kagent-default -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  resolved="$(kubectl -n kagent get workerpool kagent-default -o jsonpath='{.status.sandboxClasses[0].conditions[?(@.type=="Resolved")].status}' 2>/dev/null)"
  [[ -n "$want" && "${ready:-0}" == "$want" && "$resolved" == "True" ]]
}
wait_until 300 "WorkerPool kagent-default ready (gvisor resolved, all workers ready)" pool_ready \
  || kubectl -n kagent get workerpool kagent-default -o yaml | sed -n '/^status:/,$p' >&2
kubectl -n kagent get workerpool/kagent-default deploy/kagent-default -o wide 2>&1 | sed 's/^/    /'
