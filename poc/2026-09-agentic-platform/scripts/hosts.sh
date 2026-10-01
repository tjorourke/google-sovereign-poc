#!/usr/bin/env bash
# hosts.sh — put every *.agentic.eu0.internal name the lab serves into your
# laptop's /etc/hosts, so the browser URLs work outside the VPC.
#
#   ./scripts/hosts.sh               find the gateway's external address and write it
#   ./scripts/hosts.sh 34.3.1.2      write this address instead
#   ./scripts/hosts.sh --local       write 127.0.0.1 and print the port-forward to run
#   ./scripts/hosts.sh --print       show the block, change nothing
#   ./scripts/hosts.sh --remove      take the block out again
#
# The entries go between two marker lines, so rerunning replaces them rather
# than piling up duplicates, and --remove leaves the rest of the file alone.
# /etc/hosts is backed up to /etc/hosts.bak.google-sov before every write.
#
# Every name, agw included, points at agentgateway-proxy: one gateway, routing on
# the Host header (agw is a ListenerSet on it, see 87-vsr-routes.sh). Its own
# Service is an internal LB, which a laptop cannot reach; 80-ingress.sh with
# EXPOSE_EXTERNAL=1 (or 85-edge.sh) adds the external address this script uses.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env

BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
AGW_NS="${AGW_NS:-agentgateway-system}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
NAMES=(keycloak agentregistry kagent llm agw payments staging.payments)
BEGIN="# BEGIN google-sov agentic lab"
END="# END google-sov agentic lab"

# Find the address the gateway answers on from outside the VPC. Prefer what
# 80-ingress.sh exposes, then the 85-edge.sh ALB, and refuse a private address:
# writing a 10.x into /etc/hosts gives names that resolve and never connect.
external_ip() {
  local ip
  ip="$(kc -n "$AGW_NS" get svc agentgateway-proxy-external \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(cd "${TOFU_DIR:-$LAB_ROOT/infra}" 2>/dev/null && tofu output -raw ingress_ip 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] && ip=""
  echo "$ip"
}

block() {
  echo "$BEGIN"
  for n in "${NAMES[@]}"; do printf '%s\t%s.%s\n' "$1" "$n" "$BASE_DOMAIN"; done
  echo "$END"
}

# The file without our block, whatever state the block is in.
stripped() { sed "/^${BEGIN}\$/,/^${END}\$/d" "$HOSTS_FILE"; }

write_hosts() {  # write_hosts <content-file>
  sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.google-sov"
  sudo tee "$HOSTS_FILE" < "$1" >/dev/null
  # macOS caches lookups; without this the old answer can persist for minutes.
  if [[ "$(uname)" == Darwin ]]; then
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true
  fi
}

MODE=auto IP=""
for a in "$@"; do
  case "$a" in
    --local)  MODE=local; IP=127.0.0.1 ;;
    --print)  [[ "$MODE" == local ]] || MODE=print; PRINT=1 ;;
    --remove) MODE=remove ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        [[ "$a" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "not an IPv4 address: $a"; IP="$a" ;;
  esac
done
[[ "${PRINT:-0}" == 1 ]] && MODE=print

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

if [[ "$MODE" == remove ]]; then
  grep -qF "$BEGIN" "$HOSTS_FILE" || { ok "no google-sov block in $HOSTS_FILE"; exit 0; }
  stripped > "$TMP"
  write_hosts "$TMP"
  ok "removed the google-sov block from $HOSTS_FILE"
  exit 0
fi

if [[ -z "$IP" ]]; then
  assert_kube_reachable
  IP="$(external_ip)"
  [[ -n "$IP" ]] || die "the gateway has no external address yet. Either:
      EXPOSE_EXTERNAL=1 ./scripts/80-ingress.sh     (or ./scripts/85-edge.sh), then rerun this
      ./scripts/hosts.sh --local                    and use a port-forward"
fi

if [[ "$MODE" == print ]]; then block "$IP"; exit 0; fi

{ stripped; block "$IP"; } > "$TMP"
step "writing ${#NAMES[@]} names -> $IP into $HOSTS_FILE (sudo)"
write_hosts "$TMP"
ok "done; backup at ${HOSTS_FILE}.bak.google-sov"

SCHEME=https PORT=""
if [[ "$MODE" == local ]]; then
  SCHEME=http PORT=":8080"
  cat >&2 <<EOF

  127.0.0.1 only works while a port-forward to the gateway is running:

    KUBECONFIG=$LAB_ROOT/deploy/.kubeconfig GOOGLE_CLOUD_UNIVERSE_DOMAIN=${GOOGLE_CLOUD_UNIVERSE_DOMAIN:-apis-berlin-build0.goog} \\
      kubectl -n $AGW_NS port-forward svc/agentgateway-proxy 8080:80

  and every URL below needs :8080.
EOF
fi

cat >&2 <<EOF

  Keycloak        ${SCHEME}://keycloak.${BASE_DOMAIN}${PORT}
  AgentRegistry   ${SCHEME}://agentregistry.${BASE_DOMAIN}${PORT}
  kagent          ${SCHEME}://kagent.${BASE_DOMAIN}${PORT}      (admin-user / password)
  MCP             mesh-only Services; no external MCP route (92-mcp-lockdown.sh)
  Bank website    ${SCHEME}://payments.${BASE_DOMAIN}${PORT}
  Bank staging    ${SCHEME}://staging.payments.${BASE_DOMAIN}${PORT}
  Gemma (direct)  ${SCHEME}://llm.${BASE_DOMAIN}${PORT}/v1
  AGW models      ${SCHEME}://agw.${BASE_DOMAIN}${PORT}/v1   (Gemma / Gemini, routed by VSR; 87-vsr-routes.sh)

  The certificate is issued by the lab's private CA (GCD has no ACME or
  Certificate Manager). Trust it once and the browser stops warning:

    ./scripts/85-tls.sh --ca > /tmp/agentic-ca.crt
    sudo security add-trusted-cert -d -r trustRoot \\
      -k /Library/Keychains/System.keychain /tmp/agentic-ca.crt

  Undo with: ./scripts/hosts.sh --remove
EOF
