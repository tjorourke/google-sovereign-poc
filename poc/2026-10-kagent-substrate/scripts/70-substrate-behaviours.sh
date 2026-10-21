#!/usr/bin/env bash
# 70-substrate-behaviours.sh — the Agent Substrate behaviours 60-verify.sh does
# not cover, each attempted for real against the cluster.
#
#   api        Substrate's own API (`kubectl ate`): the shared ate-client identity
#              is refused, the ate-operator principal lists atespaces, actor
#              templates, actors with their state, tags and workers
#   multiplex  MULTIPLEX_SESSIONS (20) conversations invoked at once on the two
#              gVisor workers, then a second round: how many actors exist vs run,
#              placement over time, resume latency, parking, and actors resuming
#              on a different worker than they ran on
#   fork       checkpoint a conversation, fork it, and show the fork carries the
#              context up to the checkpoint and nothing after it
#   egress     a sandbox with no EgressPolicy reaches nothing; granting one origin
#              opens that origin, in the same running sandbox, and nothing else
#
# Usage: 70-substrate-behaviours.sh [api|multiplex|fork|egress|all]   (default all)
# Evidence: evidence/behaviours-<time>.txt, raw multiplex data in
# evidence/multiplex-<time>/. The microVM sandbox class is not tested: GKE
# Autopilot offers no nested virtualisation, so only gVisor is possible on GCD.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl python3 perl
assert_kube

WHAT="${1:-all}"
case "$WHAT" in api|multiplex|fork|egress|all) ;; *) die "usage: $0 [api|multiplex|fork|egress|all]" ;; esac

STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
OUT="$LAB_ROOT/evidence/behaviours-$STAMP.txt"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
: > "$OUT"
rec()  { printf '%s\n' "$*" >> "$OUT"; }
pass() { ok "$*"; rec "PASS  $*"; PASS=$((PASS+1)); }
fail() { warn "$*"; rec "FAIL  $*"; FAIL=$((FAIL+1)); }
section() { step "$*"; rec ""; rec "== $*"; }
show() { printf '%s\n' "$1" | sed 's/^/    /'; printf '%s\n' "$1" | sed 's/^/    /' >> "$OUT"; }
now()  { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

rec "# kagent $KAGENT_VERSION / Substrate $SUBSTRATE_VERSION / agentgateway $AGW_ENT_VERSION"
rec "# cluster $CLUSTER_NAME ($PROJECT_ID), $(date -u '+%Y-%m-%dT%H:%M:%SZ'), sections: $WHAT"

KAGENT="$(kagent_cli)"
ATE="$(ate_cli)"
TOKEN="$TMP/ate-operator.token"
ate_operator_token "$TOKEN"
KATE=("$ATE" --kubeconfig "$KUBECONFIG" --token-file "$TOKEN")

# kagent's API on a free local port, proven to be OURS (see 60-verify.sh).
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
kubectl -n kagent port-forward svc/kagent-controller "$PORT:8083" > "$TMP/pf.log" 2>&1 &
PF=$!
SAMPLER=""
cleanup() { kill $PF ${SAMPLER:-} 2>/dev/null; wait $PF ${SAMPLER:-} 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
pf_live() { kill -0 "$PF" 2>/dev/null && grep -q "Forwarding from 127.0.0.1:$PORT" "$TMP/pf.log"; }
wait_until 30 "port-forward to kagent-controller on :$PORT" pf_live || die "port-forward failed: $(cat "$TMP/pf.log")"
API="http://127.0.0.1:$PORT"
KA=("$KAGENT" --api-url "$API" --gateway-url "$API" -n kagent --timeout 5m)
MCP=(python3 "$LAB_ROOT/scripts/kagent_mcp.py" "$API")

new_session() {  # new_session AGENT -> session id
  "${KA[@]}" agent session create --agent "$1" -o json 2>/dev/null | json 'd["session"]["id"]'
}

# ── api ───────────────────────────────────────────────────────────────────────
run_api() {
  section "Substrate API view through kubectl ate"
  local r
  r="$(timeout 120 "$ATE" --kubeconfig "$KUBECONFIG" get atespaces 2>&1)"
  show "\$ kubectl ate get atespaces        # no --token-file: the shared ate-client identity"
  show "$r"
  grep -q "PermissionDenied" <<<"$r" && pass "the shared ate-client identity is refused (not a bootstrap owner)" \
    || fail "ate-client was not refused"
  local c
  for c in "get atespaces" "get actor-templates -A" "get actors -A" "get tags -A" "get workers"; do
    r="$(timeout 120 "${KATE[@]}" $c 2>&1)"
    show "\$ kubectl ate --token-file ate-operator.token $c"
    show "$r"
    if grep -q -E "^(NAME|ATESPACE)" <<<"$r"; then pass "kubectl ate $c (as ate-operator)"; else fail "kubectl ate $c"; fi
  done
}

# ── multiplex ─────────────────────────────────────────────────────────────────
# Every conversation is its own actor; a worker hosts as many as its CPU and
# memory allow (each actor reserves its 1 CPU / 1 GiB limits; a worker has
# 4 CPU / 8 GiB), so the two workers run 8 at once. A resume that finds no
# room is refused (atenet-router answers UNAVAILABLE at once; nothing parks
# it); kagent's gateway reports the send as not accepted and the kagent CLI
# re-sends it every 100 ms for up to 30 s, until an actor suspends.
sample_assignments() {  # sample_assignments FILE — runs until killed
  while :; do
    kubectl -n kagent exec deploy/kagent-postgresql -c postgresql -- psql -U postgres -d kagent -At -F, -c \
      "select to_char(clock_timestamp() at time zone 'utc', 'HH24:MI:SS.MS'), coalesce(ac.name, '-'), coalesce(a.worker_name, '-')
         from (select 1) one
         left join substrate.worker_assignments a on true
         left join substrate.actors ac on ac.uid = a.actor_uid" >> "$1" 2>/dev/null
    sleep 1
  done
}

invoke_round() {  # invoke_round ROUND TASK SESSION...
  local round="$1" task="$2"; shift 2
  local sid pids=()
  for sid in "$@"; do
    (
      t0="$(now)"
      "${KA[@]}" agent invoke --session "$sid" --task "$task" > "$RUN/out-$round-$sid.txt" 2>&1
      rc=$?
      echo "$round $sid $rc $t0 $(now)" >> "$RUN/results.txt"
    ) &
    pids+=($!)
  done
  # Only these: a bare `wait` would also wait for the sampler and port-forward.
  wait "${pids[@]}"
}

all_suspended() { [[ -z "$(kubectl -n kagent exec deploy/kagent-postgresql -c postgresql -- psql -U postgres -d kagent -At -c 'select 1 from substrate.worker_assignments limit 1' 2>/dev/null)" ]]; }

run_multiplex() {
  local n="${MULTIPLEX_SESSIONS:-20}"
  section "multiplexing: $n conversations on the gVisor WorkerPool, two rounds"
  RUN="$LAB_ROOT/evidence/multiplex-$STAMP"
  mkdir -p "$RUN"
  : > "$RUN/results.txt"
  timeout 120 "${KATE[@]}" get workers -o json 2>/dev/null \
    | python3 -c 'import json, sys
for w in json.load(sys.stdin).get("workers", []):
    print(w["metadata"]["name"], w.get("workerNamespace", "") + "/" + w.get("workerPod", ""))' > "$RUN/workers.txt"
  show "$(timeout 120 "${KATE[@]}" get workers 2>&1)"

  local sids=() i sid
  for ((i = 1; i <= n; i++)); do
    sid="$(new_session trustusbank-assistant)"
    [[ -n "$sid" ]] && sids+=("$sid")
  done
  [[ "${#sids[@]}" -eq "$n" ]] && pass "$n sessions created (one Substrate actor each)" || fail "only ${#sids[@]} of $n sessions created"
  printf '%s\n' "${sids[@]}" > "$RUN/sessions.txt"

  wait_until 120 "no actor assigned to a worker before the run" all_suspended || true
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  : > "$RUN/samples.csv"
  sample_assignments "$RUN/samples.csv" &
  SAMPLER=$!

  log "round 1: ${#sids[@]} invocations at once"
  # Substrate's own capacity accounting while the round is at its peak.
  ( sleep 6; timeout 60 "${KATE[@]}" get workers > "$RUN/workers-during-round1.txt" 2>&1 ) &
  local snap=$!
  invoke_round 1 "In about 80 words, explain why a bank cares where its AI agents run. Plain prose." "${sids[@]}"
  wait "$snap" 2>/dev/null
  show "kubectl ate get workers, during round 1:"
  show "$(cat "$RUN/workers-during-round1.txt")"
  wait_until 180 "every actor suspended again after round 1" all_suspended || true

  log "round 2: the same conversations again (their actors resume from their own snapshots)"
  invoke_round 2 "Summarise your previous answer in one sentence." "${sids[@]}"
  wait_until 180 "every actor suspended again after round 2" all_suspended || true
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; SAMPLER=""

  # Substrate's own record of every transition, from both ate-api-server replicas.
  local p
  : > "$RUN/transitions.jsonl"
  for p in $(kubectl -n ate-system get pods -o name | grep ate-api-server); do
    kubectl -n ate-system logs "$p" -c ate-api-server --since-time="$since" 2>/dev/null \
      | grep '"Actor state changed"' >> "$RUN/transitions.jsonl"
  done
  kubectl -n ate-system logs deploy/atenet-router --since-time="$since" > "$RUN/router.log" 2>&1

  local ok1 ok2
  ok1="$(awk '$1 == 1 && $3 == 0' "$RUN/results.txt" | wc -l | tr -d ' ')"
  ok2="$(awk '$1 == 2 && $3 == 0' "$RUN/results.txt" | wc -l | tr -d ' ')"
  [[ "$ok1" -eq "${#sids[@]}" ]] && pass "round 1: all $ok1 concurrent invocations answered" || fail "round 1: $ok1 of ${#sids[@]} answered"
  [[ "$ok2" -eq "${#sids[@]}" ]] && pass "round 2: all $ok2 answered, each from its own resumed actor" || fail "round 2: $ok2 of ${#sids[@]} answered"
  for f in "$RUN"/out-*.txt; do
    if grep -q -i -E "error|unavailable|failed" "$f"; then show "$(basename "$f"): $(tail -2 "$f")"; fi
  done

  local report; report="$(python3 "$LAB_ROOT/scripts/actor_timeline.py" "$RUN" 2>&1)"
  printf '%s\n' "$report" > "$RUN/report.txt"
  show "$report"
  local peak; peak="$(grep -o 'peak: [0-9]* running at once of [0-9]*' <<<"$report")"
  [[ -n "$peak" ]] && pass "multiplexed: $peak actors" || fail "no placement samples"
  grep -q -E "different worker in round 2: [1-9]" <<<"$report" \
    && pass "an actor resumed on a different worker than it ran on" \
    || fail "no actor changed worker between rounds"

  if [[ -z "${KEEP_SESSIONS:-}" ]]; then
    for sid in "${sids[@]}"; do "${KA[@]}" agent session delete "$sid" >/dev/null 2>&1; done
    log "deleted the $n test sessions (KEEP_SESSIONS=1 keeps them)"
  fi
}

# ── fork ──────────────────────────────────────────────────────────────────────
run_fork() {
  section "session checkpoint and fork (kagent MCP: create_session_checkpoint, fork_session)"
  local s1 inv t1 ck cid s2 a1 a2 q
  s1="$(new_session trustusbank-assistant)"
  [[ -n "$s1" ]] || { fail "could not create a session"; return; }
  inv="$("${KA[@]}" agent invoke --session "$s1" --task "Remember this codeword for later: KESTREL-42. Reply only with OK." -o json 2>&1)"
  t1="$(json 'd["task"]["id"]' <<<"$inv" 2>/dev/null)"
  show "session $s1: planted KESTREL-42 in task $t1"
  ck="$("${MCP[@]}" call create_session_checkpoint "{\"session_id\":\"$s1\",\"expected_head_task_id\":\"$t1\"}" 2>&1)"
  show "$ck"
  cid="$(json 'd["checkpoint"]["id"]' <<<"$ck" 2>/dev/null)"
  ckpt_ready() { "${MCP[@]}" call list_session_checkpoints "{\"session_id\":\"$s1\"}" 2>/dev/null | grep -q CHECKPOINT_STATE_READY; }
  [[ -n "$cid" ]] && wait_until 120 "checkpoint $cid ready" ckpt_ready && pass "checkpoint $cid READY at task $t1" \
    || { fail "checkpoint not created: $ck"; return; }
  "${KA[@]}" agent invoke --session "$s1" --task "Remember a second codeword too: OSPREY-7. Reply only with OK." >/dev/null 2>&1
  show "session $s1: planted OSPREY-7 AFTER the checkpoint"
  s2="$("${MCP[@]}" call fork_session "{\"checkpoint_id\":\"$cid\"}" 2>&1 | json 'd["session"]["id"]' 2>/dev/null)"
  [[ -n "$s2" ]] && pass "fork_session created session $s2" || { fail "fork_session failed"; return; }
  q="Which codewords have I given you in this conversation? List them, nothing else."
  a2="$("${KA[@]}" agent invoke --session "$s2" --task "$q" 2>&1 | tail -3)"
  a1="$("${KA[@]}" agent invoke --session "$s1" --task "$q" 2>&1 | tail -3)"
  show "fork     $s2: $a2"
  show "original $s1: $a1"
  grep -q "KESTREL-42" <<<"$a2" && ! grep -q "OSPREY-7" <<<"$a2" \
    && pass "the fork carries the context up to the checkpoint, and nothing after it" \
    || fail "fork context wrong: $a2"
  grep -q "KESTREL-42" <<<"$a1" && grep -q "OSPREY-7" <<<"$a1" \
    && pass "the original keeps its full history" || fail "original lost context: $a1"
  show "$(timeout 120 "${KATE[@]}" get tags -a kagent 2>&1 | grep -E "^ATESPACE|checkpoint-$cid")"
  "${KA[@]}" agent session delete "$s2" >/dev/null 2>&1
  "${KA[@]}" agent session delete "$s1" >/dev/null 2>&1
}

# ── egress ────────────────────────────────────────────────────────────────────
run_egress() {
  section "EgressPolicy: deny by default, then exactly one origin"
  local allowed="https://example.com" other="https://api.github.com"
  kubectl -n kagent patch sandboxtemplate trustusbank-egress --type json \
    -p '[{"op":"remove","path":"/spec/egressPolicyRefs"}]' >/dev/null 2>&1 || true
  kubectl apply -f "$LAB_ROOT/yaml/egress.yaml" | sed 's/^/    /'
  tmpl_ready() { [[ "$(kubectl -n kagent get sandboxtemplate trustusbank-egress -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; }
  wait_until 600 "SandboxTemplate trustusbank-egress Ready" tmpl_ready || { fail "template not ready"; return; }

  local since sb r
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sb="$("${KA[@]}" sandbox create trustusbank-egress --request-id "egress-$(date +%s)" --ttl 30m -o json 2>&1 | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", raw)
print(m.group(0) if m else "")')"
  [[ -n "$sb" ]] && pass "sandbox $sb created from trustusbank-egress (no EgressPolicy)" || { fail "sandbox create failed"; return; }
  probe() {  # probe URL — HTTP fetch from inside the sandbox: rc, then the first bytes of output or error
    "${KA[@]}" sandbox exec "$sb" -- sh -c "out=\$(wget -q -T 15 -O - '$1' 2>&1); echo \"rc=\$?\"; printf '%s' \"\$out\" | head -c 160 | tr '\n' ' '; echo" 2>&1 \
      | grep -v '^Process '
  }
  show "$("${KA[@]}" sandbox exec "$sb" -- sh -c 'echo "resolv.conf: $(grep nameserver /etc/resolv.conf)"; echo "routes: $(ip route | tr "\n" ";")"' 2>&1 | grep -v '^Process ')"
  r="$(probe "$allowed")"; show "before the grant, $allowed: $r"
  grep -q "rc=0" <<<"$r" && fail "$allowed reachable without an EgressPolicy" || pass "no EgressPolicy: $allowed unreachable"
  r="$(probe "$other")";   show "before the grant, $other: $r"
  grep -q "rc=0" <<<"$r" && fail "$other reachable without an EgressPolicy" || pass "no EgressPolicy: $other unreachable"
  # Not just DNS: an IP literal still meets the egress gateway, which refuses it.
  r="$(probe "http://1.1.1.1/")"; show "before the grant, http://1.1.1.1/ (IP literal, no DNS): $r"
  grep -q "403" <<<"$r" && pass "an IP literal is refused by the egress gateway (403), not routed around it" \
    || fail "IP literal not refused by the gateway: $r"

  kubectl -n kagent patch sandboxtemplate trustusbank-egress --type merge \
    -p '{"spec":{"egressPolicyRefs":[{"name":"trustusbank-egress-example"}]}}' | sed 's/^/    /'
  applied() { [[ "$(kubectl -n kagent get sandboxtemplate trustusbank-egress -o jsonpath='{.status.conditions[?(@.type=="EgressPoliciesApplied")].status}' 2>/dev/null)" == "True" ]]; }
  wait_until 120 "EgressPoliciesApplied on trustusbank-egress" applied || true
  show "$(kubectl -n kagent get sandboxtemplate trustusbank-egress -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>&1)"
  local tries=0
  until r="$(probe "$allowed")"; grep -q "rc=0" <<<"$r" || (( ++tries >= 12 )); do sleep 5; done
  show "after the grant, $allowed (same sandbox, not restarted): $r"
  grep -q "rc=0" <<<"$r" && pass "granted origin $allowed reachable from the running sandbox" || fail "$allowed still unreachable after the grant"
  r="$(probe "$other")"; show "after the grant, $other: $r"
  grep -q "rc=0" <<<"$r" && fail "$other reachable though not granted" || pass "ungranted origin $other still unreachable"

  # The gateway's request log names the actor; unresolvable names never reach it.
  local elog
  elog="$(kubectl -n ate-system logs deploy/atenet-egress --since-time="$since" 2>&1 | grep -F "$sb" \
    | grep -E "request request.id|failed to terminate TLS" | sed -E 's/(error="[^"]*").*/\1/' | cut -c1-420)"
  show "atenet-egress request log for this sandbox's actor:"
  show "$elog"
  grep -q "egress policy denied" <<<"$elog" && pass "atenet-egress logged the policy denial for this actor" \
    || fail "no policy denial in the atenet-egress log"
  "${KA[@]}" sandbox delete "$sb" >/dev/null 2>&1
  kubectl -n kagent patch sandboxtemplate trustusbank-egress --type json \
    -p '[{"op":"remove","path":"/spec/egressPolicyRefs"}]' >/dev/null 2>&1
  log "sandbox deleted; the template is back to no egress (yaml/egress.yaml)"
}

[[ "$WHAT" == all || "$WHAT" == api ]]       && run_api
[[ "$WHAT" == all || "$WHAT" == fork ]]      && run_fork
[[ "$WHAT" == all || "$WHAT" == egress ]]    && run_egress
[[ "$WHAT" == all || "$WHAT" == multiplex ]] && run_multiplex

section "summary"
rec "passed=$PASS failed=$FAIL"
printf '\n  %s passed, %s failed. Evidence: %s\n' "$PASS" "$FAIL" "${OUT#"$REPO_ROOT"/}"
[[ "$FAIL" -eq 0 ]]
