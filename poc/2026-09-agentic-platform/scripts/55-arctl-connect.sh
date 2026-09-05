#!/usr/bin/env bash
# 55-arctl-connect.sh — SOURCE this, don't run it:  source scripts/55-arctl-connect.sh
#
# Points the local arctl at Berlin's in-cluster AgentRegistry and exports a
# bearer token for it. Two GCD-specific problems make this less direct than the
# kind labs:
#
#   1. GCD has no public DNS zone, so a laptop cannot resolve
#      agentregistry.agentic.eu0.internal and cannot route to the gateway's
#      internal address. A kubectl port-forward is the portable answer and needs
#      no /etc/hosts edit.
#
#   2. AgentRegistry validates the token issuer as
#      http://keycloak.agentic.eu0.internal/realms/agentregistry. There is no
#      TLS in front of Keycloak here (no certificatemanager, no privateca in the
#      universe), so minting a token from a laptop means POSTing a password over
#      plaintext HTTP — which endpoint-protection software on a corporate laptop
#      blocks as credential phishing, returning a block page instead of a token.
#      Minting inside the cluster sidesteps that and produces a token carrying
#      exactly the issuer AR expects.
#
# Because this file is SOURCED into an interactive shell, it must not leave the
# shell modified. Two things would otherwise bite, and both did:
#
#   * lib.sh sets `set -uo pipefail`. Left in place, every subsequent prompt
#     that touches an unset variable errors — "BASHPID: unbound variable",
#     "TMUX: unbound variable" — which looks like a broken shell.
#   * lib.sh's die() calls `exit`, which in a sourced context terminates the
#     user's shell rather than the script. Mid-demo that is unrecoverable.
#
# So the body runs inside a function that returns instead of exiting, and the
# caller's shell options are saved and restored around it.

_arctl_connect() {
  local _sd _minter _tok _i
  _sd="$1"

  _bail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; return 1; }

  # shellcheck source=lib.sh
  source "$_sd/lib.sh" || { _bail "cannot source lib.sh"; return 1; }
  load_env || { _bail "load_env failed"; return 1; }
  kube_context >/dev/null 2>&1 || true

  kubectl version --request-timeout=10s >/dev/null 2>&1 || {
    _bail "cannot reach the cluster. The GCD session has most likely expired (~45 min).
    Re-authenticate, then re-run:  ../../scripts/gcd-auth.sh"
    return 1
  }

  local ar_ns="${AR_NS:-agentregistry-system}"
  local ar_port="${AR_PORT:-12121}"
  local as_user="${AS_USER:-admin-user}"
  local as_password="${AS_PASSWORD:-password}"
  local cli_client="${AR_CLI_CLIENT:-ar-cli-password}"
  local issuer="${KC_ISSUER:-http://keycloak.agentic.eu0.internal/realms/agentregistry}"

  export PATH="$HOME/.arctl/bin:$PATH"
  command -v arctl >/dev/null 2>&1 \
    || warn "arctl not on PATH (expected ~/.arctl/bin/arctl)"

  # Any pod with python3 will do -- we only need a process inside the cluster
  # that can POST to Keycloak over plaintext HTTP, because a laptop cannot
  # (GCD has no certificatemanager/privateca, so the issuer is HTTP, and
  # endpoint protection reads the password POST as credential phishing).
  #
  # This used to hardcode `-l app.kubernetes.io/name=sovereign-calc` in kagent.
  # That workload moved: the MCP tool server is now `everything-server` in the
  # `mcp` namespace, so the lookup returned nothing and the failure read as
  # "no sovereign-calc pod" rather than "the selector is stale". Probe a list of
  # candidates and take the first that genuinely has python3.
  _mp="$(python_pod)" || { _bail "no in-cluster pod with python3 to mint a token from"; return 1; }
  _minter_ns="${_mp%%/*}"; _minter="${_mp##*/}"

  _tok="$(kubectl -n "$_minter_ns" exec -i "$_minter" -- python3 -c "
import json,urllib.request,urllib.parse
d=urllib.parse.urlencode({'grant_type':'password','client_id':'$cli_client',
  'username':'$as_user','password':'$as_password'}).encode()
print(json.load(urllib.request.urlopen('$issuer/protocol/openid-connect/token',d))['access_token'])
" 2>/dev/null | tr -d '\r\n')"
  [[ -n "$_tok" ]] || { _bail "token mint failed — is Keycloak up? ($issuer)"; return 1; }
  export ARCTL_API_TOKEN="$_tok"

  # Replace any forward this script left behind, so re-sourcing is safe.
  pkill -f "port-forward.*${ar_port}:${ar_port}" >/dev/null 2>&1 || true
  sleep 1
  kubectl -n "$ar_ns" port-forward "svc/agentregistry-enterprise-server" \
    "${ar_port}:${ar_port}" >/tmp/ar-port-forward.log 2>&1 &
  export ARCTL_API_BASE_URL="http://localhost:${ar_port}"

  for _i in $(seq 1 20); do
    arctl get runtimes >/dev/null 2>&1 && break
    sleep 1
  done
  if arctl get runtimes >/dev/null 2>&1; then
    ok "arctl connected to ${ARCTL_API_BASE_URL} as ${as_user}"
  else
    warn "arctl could not reach AgentRegistry — see /tmp/ar-port-forward.log"
    return 1
  fi
}

# Save the caller's shell options, run the body, restore them unconditionally.
_ARCTL_OLD_OPTS="$(set +o)"
_arctl_connect "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ARCTL_RC=$?
eval "$_ARCTL_OLD_OPTS"

# Restoring is not enough on its own. If an earlier version of this script (or
# anything else sourcing lib.sh) already turned `nounset` on in this shell, the
# save above captures it as "on" and the restore faithfully puts it back, so the
# prompt keeps failing with "BASHPID: unbound variable". Nobody turns -u on in an
# interactive shell deliberately, so in an interactive shell force it off rather
# than preserving what is almost certainly our own pollution. An executed script
# such as 56-ar-push-agent.sh is not interactive and keeps its own -u.
case "$-" in
  *i*) set +u ;;
esac

unset -f _arctl_connect
unset _ARCTL_OLD_OPTS
