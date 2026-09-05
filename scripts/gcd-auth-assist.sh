#!/usr/bin/env bash
# gcd-auth-assist.sh — re-mint GCD credentials without clicking, by reusing a
# browser session you signed into once.
#
# WHY THIS EXISTS
# GCD has no unattended authentication (feedback/google/07): no service account
# keys (org policy forbids them), and the only IdP in the workforce pool is
# browser-only. Meanwhile gcloud's refresh token dies in hours, so a long
# deployment stops dead until a human clicks through two consent pages.
#
# What CANNOT be automated is the sign-in itself — it lands on a Google Account
# wall, and nothing here will ever see or type a credential. What CAN be
# automated is the consent click AFTER sign-in. So: sign in once, by hand, in a
# dedicated browser this script keeps alive; from then on gcloud can be
# re-authenticated on demand for as long as that browser's session lasts, which
# is far longer than a gcloud refresh token.
#
# READ THIS BEFORE USING IT
# The assist browser listens on a DevTools port bound to 127.0.0.1. Any process
# running as you can drive it and therefore mint GCD credentials as you. That is
# why it uses a DEDICATED, EMPTY profile and not your everyday one: the blast
# radius is this one session, not your whole browser. Stop it when you are done.
# On a shared or untrusted machine, do not use this at all.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SD/.." && pwd)"

PORT="${GCD_ASSIST_PORT:-9222}"
CDP="http://127.0.0.1:${PORT}"
PROFILE="${GCD_ASSIST_PROFILE:-$HOME/.config/gcd-auth-assist/profile}"
VENV="${GCD_ASSIST_VENV:-$HOME/.config/gcd-auth-assist/venv}"
CHROME="${GCD_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
LOGIN_CFG="${WIF_LOGIN_CONFIG:-$HOME/.config/gcloud/wif-login-config-berlin.json}"
CONSOLE_URL="${GCD_CONSOLE_URL:-https://console.cloud.berlin-build0.goog/}"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*" >&2; }
step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

running() { curl -s --max-time 5 "$CDP/json/version" >/dev/null 2>&1; }

ensure_venv() {
  [[ -x "$VENV/bin/python" ]] && return 0
  step "one-off: installing Playwright into $VENV"
  mkdir -p "$(dirname "$VENV")"
  python3 -m venv "$VENV" >/dev/null 2>&1 || { red "could not create the venv"; return 1; }
  "$VENV/bin/pip" install -q playwright >/dev/null 2>&1 \
    || { red "could not install playwright"; return 1; }
  grn "  ok playwright installed (drives your existing Chrome; downloads no browser)"
}

case "${1:-status}" in

start)
  [[ -x "$CHROME" ]] || { red "Chrome not found at $CHROME (set GCD_CHROME)"; exit 1; }
  ensure_venv || exit 1
  if running; then grn "  ok assist browser already up on $CDP"; else
    step "starting the assist browser (dedicated profile, empty)"
    mkdir -p "$PROFILE"
    nohup "$CHROME" --user-data-dir="$PROFILE" \
      --remote-debugging-port="$PORT" \
      --no-first-run --no-default-browser-check \
      --new-window \
      "$CONSOLE_URL" >/dev/null 2>&1 &
    for _ in $(seq 1 20); do running && break; sleep 1; done
    running || { red "assist browser did not expose $CDP"; exit 1; }
    grn "  ok assist browser up on $CDP"
  fi
  cat <<EOF

  SIGN IN ONCE, in the window that just opened:

    provider name:  locations/global/workforcePools/preview-soloio-p/providers/preview-soloio-pp

  Leave that window open. While it stays signed in, run:

    ./scripts/gcd-auth-assist.sh login     # no clicking

  and stop it when you are finished:

    ./scripts/gcd-auth-assist.sh stop
EOF
  ;;

login)
  running || { red "assist browser is not running — ./scripts/gcd-auth-assist.sh start"; exit 1; }
  [[ -x "$VENV/bin/python" ]] || { red "venv missing — ./scripts/gcd-auth-assist.sh start"; exit 1; }
  [[ -f "$LOGIN_CFG" ]] || { red "no login config at $LOGIN_CFG — run ./scripts/gcd-auth.sh once"; exit 1; }

  HELPER="$(mktemp)"; trap 'rm -f "$HELPER"' EXIT
  cat > "$HELPER" <<EOF
#!/usr/bin/env bash
exec "$VENV/bin/python" "$SD/lib/gcd-consent-click.py" "$CDP" "\$1"
EOF
  chmod +x "$HELPER"

  # Two logins, because --update-adc is refused for third-party flows and the
  # client libraries will not read the CLI credential. Both are driven headlessly.
  step "CLI credential"
  BROWSER="$HELPER" gcloud auth login --login-config="$LOGIN_CFG" 2>&1 | tail -3

  step "Application Default Credentials"
  BROWSER="$HELPER" gcloud auth application-default login --login-config="$LOGIN_CFG" 2>&1 | tail -3

  step "Result"
  ok=0
  gcloud auth print-access-token >/dev/null 2>&1 && { grn "  ok CLI credential"; ok=$((ok+1)); } || red "  CLI credential FAILED"
  gcloud auth application-default print-access-token >/dev/null 2>&1 && { grn "  ok ADC"; ok=$((ok+1)); } || red "  ADC FAILED"
  [[ "$ok" -eq 2 ]] || { ylw "If both failed, the assist browser's session has lapsed. Re-run 'start' and sign in again."; exit 1; }
  ;;

status)
  if running; then grn "  ok assist browser up on $CDP  (profile: $PROFILE)"; else
    ylw "assist browser not running"; fi
  gcloud auth print-access-token >/dev/null 2>&1 && grn "  ok gcloud CLI credential alive" || ylw "gcloud CLI credential dead"
  gcloud auth application-default print-access-token >/dev/null 2>&1 && grn "  ok ADC alive" || ylw "ADC dead"
  ;;

stop)
  pkill -f "remote-debugging-port=${PORT}" 2>/dev/null && grn "  ok assist browser stopped" || ylw "nothing to stop"
  ;;

*) echo "usage: $0 [start|login|status|stop]" >&2; exit 64 ;;
esac
