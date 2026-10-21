#!/usr/bin/env bash
# 75-gcs-roundtrip.sh — one conversation persisted to Cloud Storage and loaded
# back on another node.
#
# Turn 1 gives trustusbank-assistant a code word, and its actor suspends: the
# snapshot (the actor's /data volume) goes to gs://agentic-ate-snapshots. The
# worker pod it ran on is then deleted, so turn 2 resumes on the other worker's
# node, which never had a local copy: the snapshot can only come from GCS.
# Turn 2 asks for the word back. The session is kept, so its snapshot stays in
# the bucket to inspect. Writes evidence/gcs-roundtrip-<time>.txt.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gcloud kubectl jq python3
assert_session
assert_kube

EVIDENCE="$LAB_ROOT/evidence/gcs-roundtrip-$(date -u +%Y-%m-%dT%H%MZ).txt"
say() { printf '%s\n' "$*" | tee -a "$EVIDENCE"; }
TMP="$(mktemp -d)"
KB="$(kagent_cli)"; ATE="$(ate_cli)"
ate_operator_token "$TMP/op.token"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
kubectl -n kagent port-forward svc/kagent-controller "$PORT:8083" >"$TMP/pf.log" 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; wait $PF 2>/dev/null; rm -rf "$TMP"' EXIT
pf_live() { kill -0 "$PF" 2>/dev/null && grep -q "Forwarding from 127.0.0.1:$PORT" "$TMP/pf.log"; }
wait_until 30 "port-forward to kagent-controller on :$PORT" pf_live \
  || die "port-forward failed: $(cat "$TMP/pf.log")"

ka()  { "$KB" --api-url "http://127.0.0.1:$PORT" --gateway-url "http://127.0.0.1:$PORT" "$@"; }
ate() { timeout 60 "$ATE" --token-file "$TMP/op.token" "$@"; }
row() { ate get actors -A 2>/dev/null | grep -- "$A" || true; }
wait_suspended() { local _; for _ in $(seq 1 45); do row | grep -q SUSPENDED && return 0; sleep 2; done; return 1; }
snapshot_uri() { ate get actors -A -o yaml 2>/dev/null | grep -A40 "name: $A" | awk '/snapshotUri:/{print $2; exit}'; }
node_of() { kubectl -n kagent get pod "${1#kagent/}" -o jsonpath='{.spec.nodeName}'; }
atelet_on() { kubectl -n ate-system get pods -o wide --no-headers | awk -v n="$1" '/^atelet-/ && $7 == n {print $1}'; }
# seen_worker FN: run FN in the background; print the last worker the actor was seen on.
seen_worker() {
  "$1" & local p=$! w="" x
  while kill -0 "$p" 2>/dev/null; do
    x="$(row | awk '$5 ~ /^kagent\// {print $5}')"; [[ -n "$x" ]] && w="$x"
    sleep 1
  done
  wait "$p"
  x="$(row | awk '$5 ~ /^kagent\// {print $5}')"; [[ -n "$x" ]] && w="$x"
  printf '%s\n' "$w"
}

WORD="heron-$RANDOM"
SID="$(ka agent session create --agent trustusbank-assistant -o json | jq -r .session.id)"
A="session-$SID"
turn1() { ka agent invoke --session "$SID" --task "Remember this code word for later: $WORD. Reply with just: noted." >"$TMP/turn1.txt" 2>&1; }
turn2() { ka agent invoke --session "$SID" --task "What was the code word I gave you? Reply with just the word." >"$TMP/turn2.txt" 2>&1; }
say "# $(date -u +%FT%TZ) session $SID (actor $A), code word $WORD"

W1="$(seen_worker turn1)"; [[ -n "$W1" ]] || die "never saw turn 1's worker"
N1="$(node_of "$W1")"
say "turn 1 answered ($(tr -d '\n' <"$TMP/turn1.txt" | grep -io noted | head -1)); ran on $W1, node $N1"
wait_suspended || die "the actor did not suspend: $(row)"
URI="$(snapshot_uri)"
[[ "$URI" == gs://* ]] || die "the snapshot is not in GCS: '$URI'"
say "suspended; snapshot $URI"
sleep 5   # suspend uploads in the background
gcloud storage ls -l "$URI/**" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $3}' | sed "s|$URI/||" \
  | while read -r size obj; do say "  $(printf '%6s' "$size") bytes  $obj"; done
[[ -n "$(gcloud storage ls "$URI/manifest.json" 2>/dev/null)" ]] || die "no manifest.json under $URI"

kubectl -n kagent delete pod "${W1#kagent/}" --wait=false >/dev/null
say "deleted turn 1's worker pod ${W1#kagent/}, so the resume has to happen elsewhere"
sleep 3
T2="$(date -u +%FT%TZ)"
W2="$(seen_worker turn2)"; [[ -n "$W2" ]] || die "never saw turn 2's worker"
N2="$(node_of "$W2")"
grep -q "$WORD" "$TMP/turn2.txt" || die "turn 2 did not recall $WORD: $(tail -3 "$TMP/turn2.txt")"
say "turn 2 recalled $WORD; resumed on $W2, node $N2"
[[ "$N2" != "$N1" ]] || die "turn 2 resumed on turn 1's node, so it may have used that node's local copy"
AL="$(atelet_on "$N2")"
DL="$(kubectl -n ate-system logs "$AL" -c objectstore-plugin --since-time="$T2" | grep -c 'Decompressed zstd download' || true)"
(( DL > 0 )) || die "no GCS download logged by $AL's object-store plugin since $T2"
say "object-store plugin in $AL downloaded $DL snapshot file(s) from GCS for the resume"
wait_suspended && say "suspended again; new snapshot $(snapshot_uri)"
say "PASS: persisted to GCS on $N1, loaded from GCS on $N2. Session kept: $SID"
log "evidence: ${EVIDENCE#"$REPO_ROOT"/}"
