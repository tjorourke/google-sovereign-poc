#!/usr/bin/env bash
# gcd-session.sh — report, and optionally hold open, the GCD session.
#
# Why this exists: GCD has NO unattended authentication path (see
# feedback/google/07). A long deployment therefore runs on a credential a human
# minted in a browser, and when it dies mid-phase the failure surfaces as
# whatever the current gcloud call happened to be, not as "your session ended".
#
# Measured on 2026-09-05 against apis-berlin-build0.goog:
#   * access tokens live ~56 minutes and gcloud refreshes them automatically
#   * the refresh token is NOT rotated on use, and has its own, longer, hard
#     lifetime — when THAT expires nothing can renew it without a browser
#
#   status              one line: alive/dead, and how long since the credential
#                       was minted
#   hold [SECONDS]      refresh on an interval so a stall is noticed early,
#                       and exit non-zero the moment renewal stops working
set -uo pipefail

ADC="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"

alive() { gcloud auth print-access-token >/dev/null 2>&1; }

minted_ago() {
  [[ -f "$ADC" ]] || { echo "unknown"; return; }
  local t now
  t="$(stat -f %m "$ADC" 2>/dev/null || stat -c %Y "$ADC" 2>/dev/null)"
  [[ -n "$t" ]] || { echo "unknown"; return; }
  now="$(date +%s)"
  printf '%dh%02dm' $(( (now-t)/3600 )) $(( ((now-t)%3600)/60 ))
}

case "${1:-status}" in
  status)
    if alive; then
      printf '\033[32m  ok\033[0m GCD session alive (credential minted %s ago)\n' "$(minted_ago)"
    else
      printf '\033[31mERROR\033[0m GCD session dead — no unattended renewal exists.\n' >&2
      printf '      Run: ./scripts/gcd-auth.sh   (one browser page)\n' >&2
      exit 1
    fi
    ;;
  hold)
    every="${2:-600}"
    printf 'holding the session open, checking every %ss. Ctrl-C to stop.\n' "$every"
    while true; do
      if alive; then
        printf '\033[32m  ok\033[0m %s  alive (minted %s ago)\n' "$(date '+%H:%M:%S')" "$(minted_ago)"
      else
        printf '\033[31mEXPIRED\033[0m %s  refresh no longer works.\n' "$(date '+%H:%M:%S')" >&2
        printf '        Re-run ./scripts/gcd-auth.sh, then resume:\n' >&2
        printf '        cd poc/2026-09-agentic-platform && ./scripts/run-all.sh\n' >&2
        exit 1
      fi
      sleep "$every"
    done
    ;;
  *) echo "usage: $0 [status|hold [seconds]]" >&2; exit 64 ;;
esac
