#!/usr/bin/env bash
# run-all.sh — run the whole chain in order, and survive session expiry.
#
# WHY THIS EXISTS
#
# GCD identity for a human comes only from Workforce Identity Federation, tokens
# last well under an hour, and there is no service-account path. A full standup
# is roughly two hours of wall clock, so it CANNOT complete in one session. That
# is recorded as feedback/google/10 and it is not something we can script around.
#
# What we can do is make the chain resumable. Each phase records completion, and
# the session is checked BEFORE each phase rather than failing halfway through
# one. When the token dies, this stops cleanly and tells you how to continue.
#
#   ./scripts/run-all.sh                 run from the first incomplete phase
#   ./scripts/run-all.sh --list          show phases and their state
#   ./scripts/run-all.sh --from 40       force a restart at a given phase
#   ./scripts/run-all.sh --only 63       run exactly one phase
#   ./scripts/run-all.sh --reset         forget all recorded progress
#
# Phases are idempotent, so re-running one is safe. The exception is 63, which
# contains a ~20 minute cluster update; it detects an already-correct cluster and
# skips it.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env

STATE="$LAB_ROOT/deploy/.run-all-state"
mkdir -p "$(dirname "$STATE")"
touch "$STATE"

# id | script | needs a live cluster? | one-line description
PHASES=(
  "08|08-enable-apis.sh|no|enable the APIs a fresh GCD project leaves off"
  "10|10-tofu.sh apply|no|infrastructure: network, cluster, Cloud SQL, KMS, buckets"
  "20|20-cluster-probes.sh|yes|probes that need a live cluster"
  "15|15-mirror-images.sh|yes|mirror images into the in-universe registry"
  "25|25-cluster-baseline.sh|yes|cert-manager, External Secrets, Prometheus, Grafana"
  "62|62-istio-allowlists.sh|yes|generate the Autopilot WorkloadAllowlists"
  "63|63-allowlist-install.sh|yes|authorise them: bucket, org policy, cluster, synchroniser"
  "64|64-istio-ambient.sh|yes|Istio ambient: istiod, istio-cni, ztunnel, waypoint"
  "66|66-istio-health.sh|yes|verify ambient L4 and L7 enforcement"
  "30|30-keycloak.sh|yes|Keycloak, the single OIDC issuer"
  "40|40-kagent.sh|yes|Solo Enterprise for kagent"
  "45|45-telemetry.sh|yes|ClickHouse, OTel collector, Enterprise UI"
  "50|50-agentregistry.sh|yes|AgentRegistry against Cloud SQL over PSC"
  "70|70-agentgateway.sh|yes|enterprise agentgateway, standalone path"
  "80|80-ingress.sh|yes|Gateway, HTTPRoutes, private DNS"
  "85|85-tls.sh|yes|TLS on every browser-facing URL, and the https OIDC issuer"
  "60|60-model.sh|yes|self-hosted model inside the boundary"
  "90|90-mcp-agent.sh|yes|MCP tool server and the first agent"
  "95|95-authz-on.sh|yes|tool-level authorization at the gateway"
  "56|56-ar-push-agent.sh|yes|publish to the catalogue, deploy via the registry"
  "67|67-accesspolicy-setup.sh|yes|waypoint path governed by AccessPolicy"
  "69|69-accesspolicy-health.sh|yes|verify all three agent paths"
  # Last on purpose: it installs scrape targets for the Solo components, so
  # every one of them has to exist first or Prometheus finds nothing and the
  # status check reports zero series on a healthy cluster.
  "97|o11y-deploy.sh|yes|scrape the Solo stack, load the Grafana dashboard"
)

done_already() { grep -qx "$1" "$STATE" 2>/dev/null; }
mark_done()    { grep -qx "$1" "$STATE" 2>/dev/null || echo "$1" >> "$STATE"; }

session_alive() {
  gcloud auth print-access-token >/dev/null 2>&1
}

stop_for_auth() {
  cat >&2 <<EOF

$(printf '\033[1;33m')  SESSION EXPIRED$(printf '\033[0m')

  GCD tokens last under an hour and there is no service-account path for a
  human principal, so a full standup cannot finish in one session. This is
  expected, not a failure.

  Re-authenticate, then resume. Completed phases are remembered:

    cd $REPO_ROOT && ./scripts/gcd-auth.sh
    cd $LAB_ROOT   && ./scripts/run-all.sh

  Progress so far: $(wc -l < "$STATE" | tr -d ' ') of ${#PHASES[@]} phases.
EOF
  exit 75   # EX_TEMPFAIL: retryable, not broken
}

list_phases() {
  printf '\n  %-5s %-8s %s\n' "PHASE" "STATE" "WHAT IT DOES" >&2
  for entry in "${PHASES[@]}"; do
    IFS='|' read -r id script _needs desc <<<"$entry"
    if done_already "$id"; then st="done"; else st="pending"; fi
    printf '  %-5s %-8s %s\n' "$id" "$st" "$desc" >&2
  done
  echo >&2
}

FROM=""; ONLY=""
case "${1:-}" in
  --list)  list_phases; exit 0 ;;
  --reset) : > "$STATE"; ok "progress reset"; exit 0 ;;
  --from)  FROM="${2:?--from needs a phase id}" ;;
  --only)  ONLY="${2:?--only needs a phase id}" ;;
  "")      ;;
  *)       die "unknown option: $1. Try --list." ;;
esac

# --from means "redo this and everything after", so forget those phases.
if [[ -n "$FROM" ]]; then
  SEEN=0; KEEP="$(mktemp)"
  for entry in "${PHASES[@]}"; do
    IFS='|' read -r id _ _ _ <<<"$entry"
    [[ "$id" == "$FROM" ]] && SEEN=1
    [[ "$SEEN" -eq 0 ]] && done_already "$id" && echo "$id" >> "$KEEP"
  done
  mv "$KEEP" "$STATE"
  log "restarting at phase $FROM"
fi

step "Chain: ${#PHASES[@]} phases, $(wc -l < "$STATE" | tr -d ' ') already done"
session_alive || stop_for_auth

RAN=0
for entry in "${PHASES[@]}"; do
  IFS='|' read -r id script needs desc <<<"$entry"

  [[ -n "$ONLY" && "$ONLY" != "$id" ]] && continue
  if [[ -z "$ONLY" ]] && done_already "$id"; then
    log "skip $id (done) — $desc"
    continue
  fi

  # Check BEFORE starting, so expiry never lands mid-phase and leave a phase
  # half-applied with no record of it.
  session_alive || stop_for_auth

  # A phase that needs the cluster gets a clearer message than a kubectl error.
  #
  # Repair the recoverable case rather than reporting it as an expired session.
  # After a cluster rebuild the kubeconfig still holds the OLD endpoint and CA,
  # so kubectl fails while the credential is fine -- and stop_for_auth then
  # exits 75, which tells a wrapper to re-authenticate a credential that was
  # never the problem. That is an infinite loop, and it happened.
  if [[ "$needs" == "yes" ]] && ! timeout 25 kubectl version --request-timeout=10s >/dev/null 2>&1; then
    if session_alive; then
      warn "kubectl cannot connect but the session is valid — refreshing the"
      warn "kubeconfig (stale endpoint/CA after a cluster rebuild)"
      gcloud container clusters get-credentials "${CLUSTER_NAME:-agentic}" \
        --location "${UNIVERSE_REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1 || true
    fi
    if ! timeout 30 kubectl version --request-timeout=15s >/dev/null 2>&1; then
      if session_alive; then
        warn "phase $id needs a reachable cluster, the session is VALID, and"
        warn "refreshing the kubeconfig did not help. This is not an auth"
        warn "problem — check the cluster exists and is RUNNING:"
        warn "  gcloud container clusters list"
        exit 1
      fi
      stop_for_auth
    fi
    ok "kubeconfig refreshed"
  fi

  step "Phase $id — $desc"
  # shellcheck disable=SC2086
  if ( cd "$LAB_ROOT" && ./scripts/$script ); then
    mark_done "$id"
    ok "phase $id complete"
    RAN=$((RAN+1))
  else
    rc=$?
    # An expired token mid-phase looks like an ordinary failure. Distinguish it,
    # because the remedy is completely different.
    if ! session_alive; then
      warn "phase $id failed after the session expired"
      stop_for_auth
    fi
    warn "phase $id FAILED (exit $rc) and the session is still valid, so this is"
    warn "a real error. Fix it, then resume with:"
    warn "  ./scripts/run-all.sh              # continues from this phase"
    warn "  ./scripts/run-all.sh --only $id   # retry just this one"
    exit "$rc"
  fi
done

step "Done"
if [[ -n "$ONLY" ]]; then
  log "ran phase $ONLY"
else
  log "$RAN phase(s) ran this session; $(wc -l < "$STATE" | tr -d ' ') of ${#PHASES[@]} complete"
fi
if [[ "$(wc -l < "$STATE" | tr -d ' ')" -eq "${#PHASES[@]}" ]]; then
  ok "full chain complete"
  log "verify:  ./scripts/66-istio-health.sh  &&  ./scripts/69-accesspolicy-health.sh"
fi
