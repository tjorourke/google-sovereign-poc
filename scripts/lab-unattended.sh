#!/usr/bin/env bash
# lab-unattended.sh — run deploy-e2e.sh and keep it going across the GCD
# preview's short credential life. LAB SCAFFOLDING ONLY.
#
# THIS IS NOT PART OF THE DEPLOYMENT. deploy-e2e.sh is the real script and it
# deliberately contains no authentication logic: a customer runs it with a
# working credential and it either succeeds or reports a real failure.
#
# It exists because of one property of THIS preview environment: GCD has no
# unattended authentication at all (feedback/google/07) and its refresh token
# expires in hours, so a build that legitimately takes longer than that cannot
# finish in one go. That is a property of an unfinished preview, not of the
# architecture, and it should not shape the artefact a customer reads.
#
# deploy-e2e.sh exits 75 (EX_TEMPFAIL) on credential expiry and records which
# phases completed. This wrapper catches that, re-mints through the assist
# browser (scripts/gcd-auth-assist.sh, one human sign-in reused indefinitely)
# and resumes at the interrupted phase. Any other exit code is a real error and
# is passed straight through -- retrying those would only hide them.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_RESUMES="${MAX_RESUMES:-12}"
PORT="${GCD_ASSIST_PORT:-9222}"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
hdr(){ printf '\n\033[1;35m══ lab: %s\033[0m\n' "$*"; }

reauth() {
  hdr "credential expired — re-minting"
  if ! curl -s --max-time 5 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    red "the assist browser is not running, so this cannot re-authenticate."
    red "start it once and sign in:  ./scripts/gcd-auth-assist.sh start"
    return 1
  fi
  "$SD/gcd-auth-assist.sh" login >/dev/null 2>&1
  gcloud auth print-access-token >/dev/null 2>&1
}

attempt=0
while :; do
  attempt=$((attempt+1))
  hdr "deploy-e2e.sh (attempt $attempt)"
  "$SD/deploy-e2e.sh" "$@"
  rc=$?
  case "$rc" in
    0)  grn "  ok deployment complete"; exit 0 ;;
    75) if [[ "$attempt" -ge "$MAX_RESUMES" ]]; then
          red "gave up after $attempt credential expiries"; exit 75
        fi
        reauth || exit 75 ;;
    *)  red "deploy-e2e.sh exited $rc — a real failure, not a credential expiry"
        exit "$rc" ;;
  esac
done
