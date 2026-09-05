#!/usr/bin/env bash
# o11y-deploy.sh — the observability stack for the Solo components.
#
# SEPARATE ON PURPOSE. 25-cluster-baseline.sh installs kube-prometheus-stack as
# part of the platform; this script is what makes it useful, and it can be run,
# re-run and torn down on its own without touching the platform.
#
#   ./scripts/o11y-deploy.sh              install scrape targets + dashboards
#   ./scripts/o11y-deploy.sh --status     what is being scraped, and is it up
#   ./scripts/o11y-deploy.sh --open       port-forward Grafana and print the URL
#   ./scripts/o11y-deploy.sh --remove     take the scrape config back out
#
# WHY THIS EXISTS
# kube-prometheus-stack ships ServiceMonitors for ITSELF and nothing else, so
# out of the box Prometheus watches Prometheus. Everything that makes this
# environment worth looking at is generated and then dropped:
#
#   ztunnel        per-connection source_principal / destination_principal
#   waypoints      L7 decisions, per method and per tool
#   agentgateway   tool-authorization outcomes
#   kagent         agent and tool activity
#
# On GCD there is no managed fallback. Cloud Monitoring here cannot ingest
# custom metrics, Prometheus metrics, OpenTelemetry or the Ops Agent, and
# Cloud Logging has no log-based metrics and cannot export to BigQuery. Google's
# own recommendation on that differences page is "use PromQL and Grafana". If
# this stack does not scrape it, nobody sees it -- which also means this IS the
# audit pipeline, not a convenience.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

O11Y_NS="${O11Y_NS:-observability}"
YAML_DIR="$LAB_ROOT/o11y"

case "${1:-install}" in

install)
  step "Scrape targets for the Solo stack"
  # The Prometheus CR here selects ALL ServiceMonitors and PodMonitors in ALL
  # namespaces (empty selectors), so these are picked up wherever they live.
  kubectl apply -f "$YAML_DIR/servicemonitors.yaml" >/dev/null \
    || die "could not apply the scrape config"
  n=$(kubectl get servicemonitors,podmonitors -A -l solo.io/o11y=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ok "$n monitor(s) installed"

  step "Grafana dashboard"
  # Grafana's sidecar watches for ConfigMaps labelled grafana_dashboard=1 and
  # loads them without a restart, which is why this is a ConfigMap and not a
  # provisioning file baked into the chart.
  kubectl -n "$O11Y_NS" create configmap solo-sovereign-dashboard \
    --from-file=sovereign.json="$YAML_DIR/dashboard-sovereign.json" \
    --dry-run=client -o yaml 2>/dev/null \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml 2>/dev/null \
    | kubectl apply -f - >/dev/null \
    && ok "dashboard 'Sovereign stack' loaded (Grafana picks it up within ~60s)" \
    || warn "could not load the dashboard"

  step "Waiting for the new targets to be scraped"
  log "Prometheus reloads its config every ~30s; give it a minute."
  "$0" --status
  ;;

--status|status)
  step "Monitors installed"
  kubectl get servicemonitors,podmonitors -A -l solo.io/o11y=true \
    -o custom-columns='KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>/dev/null \
    | sed 's/^/    /' || warn "none installed — run without arguments first"

  step "Are the identity-attributed metrics actually arriving?"
  # Ask Prometheus, not the pods: a target can be up and still export nothing
  # useful, and the whole point of this stack is the principal labels.
  PF_PORT="${PF_PORT:-9099}"
  kubectl -n "$O11Y_NS" port-forward svc/kube-prometheus-stack-prometheus "${PF_PORT}:9090" \
    >/dev/null 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null' EXIT
  sleep 4
  q() { curl -s -m 10 --get --data-urlencode "query=$1" \
        "http://127.0.0.1:${PF_PORT}/api/v1/query" 2>/dev/null \
        | python3 -c "import json,sys
try:
    r=json.load(sys.stdin)['data']['result']
    print(len(r))
except Exception: print('?')" 2>/dev/null; }
  printf '    %-46s %s series\n' "connections with a source_principal" "$(q 'count by (source_principal) (istio_tcp_connections_opened_total)')"
  printf '    %-46s %s series\n' "requests seen by a waypoint"          "$(q 'count by (destination_service) (istio_requests_total)')"
  printf '    %-46s %s series\n' "targets currently UP"                 "$(q 'up == 1')"
  kill $PF 2>/dev/null; trap - EXIT
  ;;

--open|open)
  step "Grafana"
  PW="$(kubectl -n "$O11Y_NS" get secret kube-prometheus-stack-grafana \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
  cat <<EOF

  kubectl -n $O11Y_NS port-forward svc/kube-prometheus-stack-grafana 3000:80

  then open  http://localhost:3000
  user       admin
  password   ${PW:-<not readable>}

  Dashboard: "Sovereign stack: identity, policy and capacity"

EOF
  ;;

--remove|remove)
  step "Removing the scrape config and dashboard"
  kubectl delete -f "$YAML_DIR/servicemonitors.yaml" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$O11Y_NS" delete configmap solo-sovereign-dashboard --ignore-not-found >/dev/null 2>&1
  ok "removed (kube-prometheus-stack itself is left alone — that is 25-cluster-baseline.sh's)"
  ;;

*) die "usage: $0 [install|--status|--open|--remove]" ;;
esac
