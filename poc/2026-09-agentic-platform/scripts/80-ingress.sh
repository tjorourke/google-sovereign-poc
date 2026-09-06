#!/usr/bin/env bash
# 80-ingress.sh — the ingress Gateway, the console routes, and the DNS handover.
#
# Three differences from the kind lab:
#   1. No NodePort patch. kind pinned the Gateway Service to nodePort 30080 so
#      the host :80 mapping could reach it. Here it is a real LoadBalancer.
#   2. The Gateway Service is annotated for NEGs, which is what lets the
#      regional external ALB in 85-edge.sh use it as a backend.
#   3. The private DNS records are RE-POINTED from Keycloak's ClusterIP (set by
#      30-keycloak.sh so OIDC discovery worked early) to the gateway address.
#      The hostnames never change, so no token ends up with a stale iss.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl jq
load_env
assert_universe

NS=agentgateway-system
GW=agentgateway-proxy
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
# internal: a regional internal ALB, reachable inside the VPC. This is the
# customer-shaped default. 85-edge.sh adds the external tier on top.
LB_SCOPE="${LB_SCOPE:-internal}"

step "Gateway '$GW' on the enterprise-agentgateway GatewayClass"
kc apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW}
  namespace: ${NS}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
YAML
ok "Gateway applied"

# Re-attach the HTTPS listener if 85-tls.sh has already run.
#
# The apply above declares the http listener ONLY, so re-running this phase on a
# cluster that already has TLS strips the https listener that 85-tls.sh added.
# The gateway controller then drops listener-443 from the Service, the external
# LoadBalancer stops answering on 443, and every https:// URL dies with a bare
# connection failure -- while the certificate, the Gateway and the HTTPRoutes
# all still look perfectly healthy. Nothing in the output says TLS was removed.
#
# Idempotence has to survive being run out of order, so restore it here rather
# than relying on 85 being re-run afterwards.
if kc -n "$NS" get secret agentic-edge-tls >/dev/null 2>&1; then
  step "restoring the HTTPS listener (TLS was already configured)"
  kc -n "$NS" patch gateway "$GW" --type=json -p '[{
    "op":"add","path":"/spec/listeners/-","value":{
      "name":"https","protocol":"HTTPS","port":443,
      "allowedRoutes":{"namespaces":{"from":"All"}},
      "tls":{"mode":"Terminate","certificateRefs":[{"name":"agentic-edge-tls"}]}}}]' \
    >/dev/null 2>&1 \
    && ok "https listener restored" \
    || warn "could not restore the https listener — re-run ./scripts/85-tls.sh"
fi

# Only route to consoles that actually exist. The Enterprise UI lives in the
# solo-enterprise namespace, which 45-telemetry.sh creates; applying its route
# before that namespace exists fails the whole manifest.
UI_ROUTE=1
kc get ns solo-enterprise >/dev/null 2>&1 || { UI_ROUTE=0; warn "solo-enterprise namespace absent — skipping the Enterprise UI route (run 45-telemetry.sh first if you want it)"; }

step "HTTPRoutes for the consoles"
kc apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: keycloak, namespace: keycloak }
spec:
  parentRefs: [{ name: ${GW}, namespace: ${NS} }]
  hostnames: ["keycloak.${BASE_DOMAIN}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: keycloak, port: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: agentregistry, namespace: agentregistry-system }
spec:
  parentRefs: [{ name: ${GW}, namespace: ${NS} }]
  hostnames: ["agentregistry.${BASE_DOMAIN}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: agentregistry-enterprise-server, port: 12121 }]
YAML

if (( UI_ROUTE )); then
  kc apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: kagent-ui, namespace: solo-enterprise }
spec:
  parentRefs: [{ name: ${GW}, namespace: ${NS} }]
  hostnames: ["kagent.${BASE_DOMAIN}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: solo-enterprise-ui, port: 80 }]
YAML
  ok "3 HTTPRoutes applied"
else
  ok "2 HTTPRoutes applied (keycloak, agentregistry)"
fi

# Size the DATA PLANE before it is programmed. The chart's `resources` value
# only reaches the controller; the proxy pods are controller-created, so
# AgentgatewayParameters is the only knob. Unsized they are defaulted by
# Autopilot to 500m/2Gi each, which on a 24-vCPU quota is capacity the later
# phases need. See yaml/sizing/agentgateway-parameters.yaml.
step "right-sizing the gateway data plane"
if kc apply -f "$LAB_ROOT/yaml/sizing/agentgateway-parameters.yaml" >/dev/null 2>&1; then
  kc -n "$NS" patch gateway "$GW" --type=merge -p \
    '{"spec":{"infrastructure":{"parametersRef":{"group":"agentgateway.dev","kind":"AgentgatewayParameters","name":"right-sized"}}}}' \
    >/dev/null 2>&1 \
    && ok "proxy pods sized 100m/256Mi (Autopilot would default them to 500m/2Gi)" \
    || warn "could not attach AgentgatewayParameters; proxies keep the Autopilot default"
else
  warn "could not apply AgentgatewayParameters; proxies keep the Autopilot default"
fi

step "waiting for the Gateway to be Programmed"
for i in $(seq 1 40); do
  [[ "$(kc -n "$NS" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]] && break
  sleep 5
done
[[ "$(kc -n "$NS" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]] \
  || { kc -n "$NS" describe gateway "$GW" >&2; die "Gateway did not reach Programmed"; }
ok "Gateway Programmed"

# ── the Service the controller provisioned ───────────────────────────────────
GW_SVC="$(kc -n "$NS" get svc -l "gateway.networking.k8s.io/gateway-name=${GW}" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$GW_SVC" ]] || die "no Service for the Gateway"
ok "gateway service: $GW_SVC"

step "making it a $LB_SCOPE LoadBalancer, with NEGs for the external ALB"
# GCD has regional load balancers only. The internal annotation gives a regional
# internal passthrough/ALB address inside the VPC; the NEG annotation is what
# 85-edge.sh needs to attach a regional EXTERNAL ALB in front.
ANNOTATIONS=('cloud.google.com/neg={"exposed_ports":{"80":{}}}')
if [[ "$LB_SCOPE" == "internal" ]]; then
  ANNOTATIONS+=('networking.gke.io/load-balancer-type=Internal')
fi
for a in "${ANNOTATIONS[@]}"; do
  kc -n "$NS" annotate svc "$GW_SVC" "$a" --overwrite >/dev/null
done
kc -n "$NS" patch svc "$GW_SVC" -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
ok "annotated and patched to LoadBalancer"

step "waiting for a load balancer address"
# Wait for an address that MATCHES THE REQUESTED SCOPE, not merely for any
# address. A Service annotated load-balancer-type=Internal can publish an
# EXTERNAL address first and only later be re-ensured as an ILB -- the events
# read Ensuring/EnsuredLoadBalancer well after .status first populates. Taking
# the first address wrote a transient external IP (34.3.133.186) into every
# private DNS record while the real ILB settled on 10.20.0.43, so every
# hostname resolved to an address nothing served and each downstream caller
# failed with a bare connection timeout.
is_private_ip() {
  case "$1" in
    10.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}
LB_IP=""
for i in $(seq 1 60); do
  CAND="$(kc -n "$NS" get svc "$GW_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "$CAND" ]]; then
    if [[ "$LB_SCOPE" != "internal" ]]; then
      LB_IP="$CAND"; break
    elif is_private_ip "$CAND"; then
      LB_IP="$CAND"; break
    else
      # Announce it once so the transient value is visible in the log rather
      # than silently discarded.
      [[ "${WARNED_EXTERNAL:-0}" == "1" ]] || {
        log "ignoring transient external address $CAND; waiting for the internal LB"
        WARNED_EXTERNAL=1
      }
    fi
  fi
  sleep 5
done
if [[ -z "$LB_IP" ]]; then
  kc -n "$NS" describe svc "$GW_SVC" >&2
  kc -n "$NS" get events --sort-by=.lastTimestamp | tail -20 >&2
  die "no $LB_SCOPE load balancer address after 5m — record this verbatim, it is probe 0.12 answering no"
fi
ok "load balancer: $LB_IP ($LB_SCOPE)"

# ── DNS handover ─────────────────────────────────────────────────────────────
step "re-pointing private DNS at the gateway (issuer string unchanged)"
HOSTS=(keycloak agentregistry); (( UI_ROUTE )) && HOSTS+=(kagent)
for h in "${HOSTS[@]}"; do
  dns_upsert "${h}.${BASE_DOMAIN}" "$LB_IP"
done

NEG_STATUS="$(kc -n "$NS" get svc "$GW_SVC" -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' 2>/dev/null || true)"

# ── optional laptop access ───────────────────────────────────────────────────
# The Gateway's Service is internal, so *.BASE_DOMAIN is unreachable from a
# laptop. This adds a SECOND Service selecting the same gateway pods, so the
# identical host-based HTTPRoutes work from outside the VPC. The internal
# Service is untouched: in-cluster traffic and the DNS records do not change.
if [[ "${EXPOSE_EXTERNAL:-0}" == "1" ]]; then
  step "external LoadBalancer for the gateway (EXPOSE_EXTERNAL=1)"
  kc apply -f "$REPO_ROOT/docs/demo/agentgateway-external-lb.yaml" >/dev/null 2>&1 \
    || warn "could not apply the external gateway Service"
  for _ in $(seq 1 30); do
    GW_IP="$(kc -n "$NS" get svc agentgateway-proxy-external \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    [[ -n "$GW_IP" ]] && break
    sleep 10
  done
  if [[ -n "${GW_IP:-}" ]]; then
    ok "gateway reachable at http://${GW_IP}"
    log "add to /etc/hosts, all on this one address:"
    # Every hostname the gateway serves, kagent INCLUDED. Leaving the kagent
    # UI out of this list is how you end up with a working Enterprise console
    # that the one person who wants to open it cannot resolve.
    #
    # HOSTS above holds only the CONSOLE hostnames (and kagent only when its
    # route was created), while mcp and llm are always routed. Expand the array
    # properly -- ${HOSTS:-...} would silently yield just its first element.
    for h in ${HOSTS[@]+"${HOSTS[@]}"} mcp llm; do
      log "  ${GW_IP}  ${h}.${BASE_DOMAIN}"
    done
  else
    warn "external LoadBalancer has no address yet"
  fi
fi

cat >&2 <<EOF

  Consoles, resolvable inside the VPC via the Cloud DNS private zone:
    http://keycloak.${BASE_DOMAIN}
    http://agentregistry.${BASE_DOMAIN}
    http://kagent.${BASE_DOMAIN}       (admin-user / password)

  NEG status for the external tier: ${NEG_STATUS:-<none yet, wait and re-check>}

  From your laptop you have two options:
    a) add the external tier:  ./scripts/85-edge.sh   (regional external ALB +
       Cloud Armor + BYO TLS, then put its IP in /etc/hosts)
    b) stay internal:  kubectl --context $(kube_context) -n ${NS} \\
         port-forward svc/${GW_SVC} 8080:80
       and add to /etc/hosts:  127.0.0.1 keycloak.${BASE_DOMAIN} ...

  Next: ./scripts/85-edge.sh, then ./scripts/90-mcp-agent.sh
EOF
