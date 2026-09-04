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
LB_IP=""
for i in $(seq 1 60); do
  LB_IP="$(kc -n "$NS" get svc "$GW_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$LB_IP" ]] && break
  sleep 5
done
if [[ -z "$LB_IP" ]]; then
  kc -n "$NS" describe svc "$GW_SVC" >&2
  kc -n "$NS" get events --sort-by=.lastTimestamp | tail -20 >&2
  die "no load balancer address after 5m — record this verbatim, it is probe 0.12 answering no"
fi
ok "load balancer: $LB_IP"

# ── DNS handover ─────────────────────────────────────────────────────────────
step "re-pointing private DNS at the gateway (issuer string unchanged)"
HOSTS=(keycloak agentregistry); (( UI_ROUTE )) && HOSTS+=(kagent)
for h in "${HOSTS[@]}"; do
  dns_upsert "${h}.${BASE_DOMAIN}" "$LB_IP"
done

NEG_STATUS="$(kc -n "$NS" get svc "$GW_SVC" -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' 2>/dev/null || true)"

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
