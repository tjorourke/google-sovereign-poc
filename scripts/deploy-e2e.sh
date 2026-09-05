#!/usr/bin/env bash
# deploy-e2e.sh — stand the whole sovereign stack up, end to end, unattended.
#
#   ./scripts/deploy-e2e.sh              resume/continue (safe to re-run)
#   ./scripts/deploy-e2e.sh --fresh      forget phase state and run everything
#   ./scripts/deploy-e2e.sh --recreate   REPLACE the GKE cluster first, then run
#
# What it builds, all Solo ENTERPRISE (no OSS components):
#   infrastructure -> Autopilot cluster -> Autopilot privileged-workload
#   allowlists -> Solo Enterprise for Istio (ambient, L4 + L7 waypoint) ->
#   Keycloak -> kagent Enterprise -> Enterprise UI -> AgentRegistry Enterprise ->
#   enterprise agentgateway -> ingress -> self-hosted model -> MCP + agents ->
#   tool authz -> AccessPolicy, then health-checks the lot.
#
# Re-running is safe: run-all.sh records which phases completed, so this resumes
# rather than repeating work. Every Solo component is the ENTERPRISE build and
# needs a licence key; they are read from the secrets file below and are never
# committed.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SD/.." && pwd)"
LAB="$REPO/poc/2026-09-agentic-platform"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
hdr(){ printf '\n\033[1;34m══ %s\033[0m\n' "$*"; }

FRESH=0; RECREATE=0
for a in "$@"; do
  case "$a" in
    --fresh)    FRESH=1 ;;
    --recreate) RECREATE=1 ;;
    *) red "unknown flag: $a"; exit 64 ;;
  esac
done

# ── licences ────────────────────────────────────────────────────────────────
# Every Solo component here is the Enterprise build and each needs a key. They
# live outside this repo and are never committed.
SECRETS="${SOLO_SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
if [[ -f "$SECRETS" ]]; then
  set -a; # shellcheck disable=SC1090
  source "$SECRETS" >/dev/null 2>&1 || true; set +a
fi
missing=""
for v in SOLO_LICENSE_KEY AGENTGATEWAY_LICENSE_KEY SOLO_ISTIO_LICENSE_KEY; do
  eval "val=\${$v:-}"; [[ -n "$val" ]] || missing="$missing $v"
done
[[ -z "$missing" ]] || { red "missing licence key(s):$missing"; red "expected in $SECRETS"; exit 1; }
grn "  ok licences present (kagent/UI, agentgateway, Istio)"

# ── credential check ────────────────────────────────────────────────────────
# ONE check, and no authentication logic. This script is run with a working
# credential and either succeeds or reports a real failure.
#
# In the GCD PREVIEW specifically there is no unattended auth path at all
# (feedback/google/07) and tokens expire in hours, so a standup can outlive its
# credential. That is a property of an unfinished preview, not of this
# architecture, and it does not belong in the deployment. scripts/lab-unattended.sh
# handles it for our environment by catching exit 75 and resuming.
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  red "no valid credential. Authenticate, then re-run -- completed phases are"
  red "remembered, so it resumes where it stopped:"
  red "  ./scripts/gcd-auth.sh"
  exit 75
fi
grn "  ok credential valid"

# ── optional cluster replacement ────────────────────────────────────────────
if [[ "$RECREATE" -eq 1 ]]; then
  hdr "replacing the GKE cluster (destroy + create, ~25 min)"
  # -replace rather than a full destroy: Cloud SQL, KMS (prevent_destroy), the
  # network and the buckets are all fine and take far longer to rebuild than
  # the cluster. This is the teardown that actually matters, because every
  # in-cluster assumption is rebuilt from nothing.
  # Go through 10-tofu.sh, not a bare `tofu apply`: it owns the backend
  # reconfigure, the profile var-file and the stage variable, and a direct
  # invocation fails immediately on unset root variables.
  ( cd "$LAB" \
    && TOFU_REPLACE='module.cluster_autopilot[0].google_container_cluster.this' \
       ./scripts/10-tofu.sh apply ) \
    || { red "cluster replacement failed"; exit 1; }
  grn "  ok cluster replaced"
  # Everything in-cluster is gone; only the infra phases still hold.
  printf '08\n10\n' > "$LAB/deploy/.run-all-state"
fi

[[ "$FRESH" -eq 1 ]] && : > "$LAB/deploy/.run-all-state"

# ── the build ───────────────────────────────────────────────────────────────
hdr "building"
( cd "$LAB" && ./scripts/run-all.sh )
rc=$?
case "$rc" in
  0)  grn "  ok all phases complete" ;;
  75) red "the credential expired mid-build. Re-authenticate and re-run; it"
      red "resumes at the interrupted phase."
      exit 75 ;;
  *)  red "run-all.sh failed with exit $rc"
      red "fix it, then re-run: ./scripts/deploy-e2e.sh   (resumes at that phase)"
      exit "$rc" ;;
esac

# ── verify ──────────────────────────────────────────────────────────────────
hdr "verification"
fail=0
( cd "$LAB" && ./scripts/66-istio-health.sh ) || fail=1
( cd "$LAB" && ./scripts/69-accesspolicy-health.sh ) || fail=1
if [[ "$fail" -eq 0 ]]; then
  hdr "DONE"
  grn "  Istio ambient L4 + L7 enforcing, all three agent paths healthy."
  ( cd "$LAB" && ./scripts/97-endpoints.sh 2>/dev/null ) || true
else
  red "the stack is up but a health check failed — see above"
  exit 1
fi
