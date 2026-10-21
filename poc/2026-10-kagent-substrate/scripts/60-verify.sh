#!/usr/bin/env bash
# 60-verify.sh — prove the platform end to end and write the evidence.
#
#   1. Substrate and kagent control planes healthy; gVisor workers running
#   2. GPU workloads refused
#   3. an agent conversation: kagent -> Substrate actor (gVisor) -> agentgateway -> OpenAI
#   4. a standalone sandbox is a gVisor sandbox: its kernel is gVisor's, not the node's
#   5. actor state survives suspend/resume (snapshot to Cloud Storage and restore)
#   6. an agent drives a sandbox through kagent's own MCP tools
#
# Each check is attempted, not asserted. Evidence: evidence/verify-<time>.txt
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl python3
assert_kube

KAGENT="$(kagent_cli)"
OUT="$LAB_ROOT/evidence/verify-$(date -u +%Y-%m-%dT%H%MZ).txt"
PASS=0; FAIL=0
: > "$OUT"
rec()  { printf '%s\n' "$*" >> "$OUT"; }
pass() { ok "$*"; rec "PASS  $*"; PASS=$((PASS+1)); }
fail() { warn "$*"; rec "FAIL  $*"; FAIL=$((FAIL+1)); }
section() { step "$*"; rec ""; rec "== $*"; }
show() { printf '%s\n' "$1" | sed 's/^/    /'; printf '%s\n' "$1" | sed 's/^/    /' >> "$OUT"; }

# First UUID-looking id in a CLI JSON (or text) response.
first_id() {
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
def walk(o):
    if isinstance(o, dict):
        for k in ("id", "sessionId", "sandboxId", "session_id", "sandbox_id"):
            v = o.get(k)
            if isinstance(v, str) and v: return v
        for v in o.values():
            r = walk(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = walk(v)
            if r: return r
try:
    r = walk(json.loads(raw))
except ValueError:
    r = None
if not r:
    m = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", raw)
    r = m.group(0) if m else ""
print(r)'
}

rec "# kagent $KAGENT_VERSION / Substrate $SUBSTRATE_VERSION / agentgateway $AGW_ENT_VERSION"
rec "# cluster $CLUSTER_NAME ($PROJECT_ID), $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── 1 ──────────────────────────────────────────────────────────────────────────
section "1. control planes and gVisor workers"
show "$(kubectl -n ate-system get deploy,ds 2>&1)"
show "$(kubectl -n kagent get deploy,workerpool 2>&1)"
NOTREADY="$(kubectl -n ate-system get deploy -o jsonpath='{range .items[?(@.status.availableReplicas!=@.status.replicas)]}{.metadata.name} {end}' 2>/dev/null)"
[[ -z "$NOTREADY" ]] && pass "all Substrate deployments available" || fail "Substrate deployments not available: $NOTREADY"
DS="$(kubectl -n ate-system get ds atelet -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
[[ -n "$DS" && "${DS%/*}" == "${DS#*/}" && "${DS%/*}" -gt 0 ]] && pass "atelet on every node ($DS)" || fail "atelet ready $DS"
W="$(kubectl -n kagent get deploy kagent-default -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
[[ "${W:-0}" -ge 1 ]] && pass "gVisor worker pods available: $W" || fail "no available gVisor workers"
show "$(kubectl get sandboxconfig gvisor-default -o jsonpath='sandboxClass={.spec.sandboxClass} defaultVersion={.spec.defaultVersion}' 2>&1)"

# ── 2 ──────────────────────────────────────────────────────────────────────────
section "2. GPU workloads refused"
G="$(kubectl -n kagent apply --dry-run=server -f - 2>&1 <<'YAML' || true
apiVersion: v1
kind: Pod
metadata: { name: gpu-probe }
spec:
  nodeSelector: { cloud.google.com/gke-accelerator: nvidia-h100-80gb }
  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      resources: { limits: { nvidia.com/gpu: "1" } }
YAML
)"
grep -q "GPU access is disabled" <<<"$G" && pass "H100 pod refused by deny-gpu-workloads" || fail "GPU pod not refused: $G"

# ── kagent API ─────────────────────────────────────────────────────────────────
# A free port, and proof the forward is OURS: on 2026-10-21 a days-old
# port-forward to a kind cluster's kagent held the port picked first, and the
# CLI quietly talked to that instead.
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
kubectl -n kagent port-forward svc/kagent-controller "$PORT:8083" > "$LAB_ROOT/deploy/pf.log" 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
pf_live() { kill -0 "$PF" 2>/dev/null && grep -q "Forwarding from 127.0.0.1:$PORT" "$LAB_ROOT/deploy/pf.log"; }
wait_until 30 "port-forward to Berlin's kagent-controller on :$PORT" pf_live \
  || die "port-forward failed: $(cat "$LAB_ROOT/deploy/pf.log")"
API="http://127.0.0.1:$PORT"
KA=("$KAGENT" --api-url "$API" --gateway-url "$API" -n kagent --timeout 5m)

# ── 3 ──────────────────────────────────────────────────────────────────────────
section "3. agent conversation (actor in gVisor -> agentgateway -> OpenAI)"
show "$("${KA[@]}" agent list 2>&1)"
SID="$("${KA[@]}" agent session create --agent trustusbank-assistant -o json 2>&1 | first_id)"
if [[ -n "$SID" ]]; then
  pass "session $SID created for trustusbank-assistant"
  R="$("${KA[@]}" agent invoke --session "$SID" --task "In one sentence: who are you, and where do you run?" 2>&1)"
  show "$R"
  if [[ -n "$R" ]] && ! grep -qi -E "error|failed|timed out" <<<"$R"; then pass "trustusbank-assistant answered"; else fail "trustusbank-assistant did not answer"; fi
  AGWLOG="$(kubectl -n agentgateway-system logs deploy/agentgateway-proxy --since=10m 2>/dev/null | grep -c 'chat/completions' || true)"
  [[ "${AGWLOG:-0}" -ge 1 ]] && pass "agentgateway logged $AGWLOG chat completion(s) in the last 10 minutes" || fail "no chat completions in the agentgateway log"
else
  fail "could not create a session for trustusbank-assistant"
fi

# ── 4 + 5 ─────────────────────────────────────────────────────────────────────
section "4. standalone sandbox runs under gVisor"
NODEK="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
show "node kernel (Container-Optimized OS): $NODEK"
RID="verify-$(date +%s)"
SB="$("${KA[@]}" sandbox create trustusbank-scratch --request-id "$RID" --ttl 30m -o json 2>&1 | first_id)"
if [[ -n "$SB" ]]; then
  pass "sandbox $SB created from trustusbank-scratch"
  K="$("${KA[@]}" sandbox exec "$SB" -- sh -c 'echo "uname: $(uname -sr)"; echo; dmesg 2>&1 | head -n 15' 2>&1)"
  show "$K"
  grep -qi "gvisor" <<<"$K" && pass "the sandbox's kernel log is gVisor's (dmesg names gVisor)" || fail "no gVisor marker in the sandbox's dmesg"
  SK="$(grep -o 'uname: .*' <<<"$K" | head -1)"
  [[ -n "$SK" && "$SK" != *"$NODEK"* ]] && pass "sandbox kernel ($SK) is not the node's ($NODEK)" || fail "sandbox kernel matches the node: $SK"

  section "5. actor state survives suspend and resume"
  "${KA[@]}" sandbox exec "$SB" -- sh -c "echo $RID > /data/workspace/proof.txt" >/dev/null 2>&1
  S1="$("${KA[@]}" sandbox suspend "$SB" 2>&1)"; show "suspend: $(tail -1 <<<"$S1")"
  S2="$("${KA[@]}" sandbox resume "$SB" 2>&1)"; show "resume:  $(tail -1 <<<"$S2")"
  P="$("${KA[@]}" sandbox exec "$SB" -- cat /data/workspace/proof.txt 2>&1)"
  show "after resume: $P"
  grep -q "$RID" <<<"$P" && pass "file written before suspend is there after resume" || fail "state lost across suspend/resume"
  "${KA[@]}" sandbox delete "$SB" >/dev/null 2>&1 && pass "sandbox deleted" || fail "sandbox delete"
else
  fail "could not create a sandbox from trustusbank-scratch"
fi

# ── 6 ──────────────────────────────────────────────────────────────────────────
section "6. an agent drives a gVisor sandbox through kagent's MCP tools"
SID2="$("${KA[@]}" agent session create --agent trustusbank-sandbox-ops -o json 2>&1 | first_id)"
if [[ -n "$SID2" ]]; then
  R2="$("${KA[@]}" agent invoke --session "$SID2" --task 'Run this command in a sandbox and show me the output: uname -sr && dmesg | head -n 3' 2>&1)"
  show "$R2"
  grep -qi -E "gvisor|4\.4\.0" <<<"$R2" && pass "trustusbank-sandbox-ops ran it in a gVisor sandbox" || fail "agent reply shows no gVisor kernel"
else
  fail "could not create a session for trustusbank-sandbox-ops"
fi

section "summary"
rec "passed=$PASS failed=$FAIL"
printf '\n  %s passed, %s failed. Evidence: %s\n' "$PASS" "$FAIL" "${OUT#"$REPO_ROOT"/}"
[[ "$FAIL" -eq 0 ]]
