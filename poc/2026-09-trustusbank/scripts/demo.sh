#!/usr/bin/env bash
# demo.sh — run the SEPA Instant fraud triage end to end.
#
# One A2A call into the orchestrator. It delegates to the fraud desk and the
# sanctions desk over A2A, each of which calls its own MCP tools through its own
# waypoint under its own AccessPolicy, and then opens a case. Nothing here is
# scripted: the delegation is the model following its system message, and the
# tool boundaries are enforced whether it cooperates or not.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="$(cd "$SD/../../2026-09-agentic-platform" && pwd)"
export KUBECONFIG="${GCD_KUBECONFIG:-$PLATFORM/deploy/.kubeconfig}"
NS=trustusbank
hdr(){ printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
log(){ printf '    %s\n' "$*"; }

timeout 25 kubectl version --request-timeout=10s >/dev/null 2>&1 || {
  printf '\n\033[1;31m✗ cannot reach the cluster. Re-authenticate first.\033[0m\n\n' >&2; exit 75; }

POD="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null \
  | awk '$1 ~ /^zahlungstriage-/ && $3=="Running" {print $1; exit}')"
[[ -n "$POD" ]] || { echo "no running zahlungstriage pod" >&2; exit 1; }

cat <<'EOF'

  TrustUsBank AG — payments financial-crime desk
  ─────────────────────────────────────────────────────────────────
  A SEPA Instant transfer of EUR 9,850 from DE89 3704 0044 0532 0130 00
  has been held. It is the fourth transfer to the same new counterparty
  in eighteen minutes, against a normal weekly outflow of EUR 280.

  The Instant Payments Regulation gives the bank seconds, not hours.

EOF
hdr "Handing the case to the triage orchestrator over A2A"
log "this runs three agents and several tool calls on a 3B CPU model — allow 2-4 minutes"

OUT="$(kubectl -n "$NS" exec -i "$POD" -c kagent -- python3 - \
  "A held SEPA Instant payment needs triage. Follow your instructions for IBAN DE89370400440532013000." \
  < "$SD/probe.py" 2>/dev/null)"

hdr "Tools the orchestrator invoked"
printf '    %s\n' "$(sed -n 's/^TOOLS=//p' <<<"$OUT")"
hdr "Outcome"
sed -n 's/^ANSWER=//p' <<<"$OUT" | fold -s -w 76 | sed 's/^/    /'

hdr "Who did what, from the mesh's point of view"
log "every hop below is mTLS with a SPIFFE identity, so the trail is attributable"
for a in zahlungstriage betrugsanalyse sanktionspruefung; do
  p="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk -v d="$a" '$1 ~ "^"d"-" && $3=="Running"{print $1;exit}')"
  printf '    %-20s %s\n' "$a" "spiffe://cluster.local/ns/$NS/sa/${a}"
done
echo
