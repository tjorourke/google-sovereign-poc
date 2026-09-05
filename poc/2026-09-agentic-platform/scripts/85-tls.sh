#!/usr/bin/env bash
# 85-tls.sh — put TLS in front of every browser-facing URL.
#
#   ./scripts/85-tls.sh            issue the cert, add the HTTPS listener,
#                                  move the OIDC issuer to https
#   ./scripts/85-tls.sh --verify   prove each URL serves TLS
#   ./scripts/85-tls.sh --ca       print the CA cert to trust on your laptop
#
# WHAT THIS CAN AND CANNOT GIVE YOU, SAID PLAINLY
# GCD has no path to a publicly-trusted certificate: no Certificate Manager, no
# Google-managed certs, no privateca, and Cloud DNS has NO PUBLIC ZONES so
# neither ACME challenge is possible. Certificates here are BYO and manual.
# What this script does is issue one from the cluster's own CA
# (ClusterIssuer/agentic-ca, from 25-cluster-baseline.sh) and terminate TLS at
# the gateway. Browsers will warn until you trust that CA -- run --ca.
#
# WHAT IS DELIBERATELY LEFT ON http
# In-cluster service-to-service calls (llm.*, mcp.*, the *.svc.cluster.local
# names). Those are already encrypted: ztunnel gives every enrolled workload
# mTLS with a SPIFFE identity, which is stronger than server-auth TLS because
# it authenticates BOTH ends. Wrapping them in HTTPS as well would mean every
# client trusting the internal CA for no additional protection, and would hide
# the identity attribution that makes the audit story work. TLS at the edge,
# mTLS inside, is the architecture -- not a compromise.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
GW_NS="${AGW_NS:-agentgateway-system}"
GW="${AGW_GATEWAY:-agentgateway-proxy}"
HOSTS="keycloak kagent agentregistry mcp llm"

case "${1:-install}" in

--ca|ca)
  kubectl -n "$GW_NS" get secret agentic-edge-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d
  exit 0
  ;;

--verify|verify)
  step "Does every browser-facing URL serve TLS?"
  IP="$(kubectl -n "$GW_NS" get svc agentgateway-proxy-external \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  [[ -n "$IP" ]] || IP="$(kubectl -n "$GW_NS" get svc "$GW" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  [[ -n "$IP" ]] || die "no gateway address"
  CA="$(mktemp)"; "$0" --ca > "$CA" 2>/dev/null
  fail=0
  for h in $HOSTS; do
    # --resolve, not /etc/hosts: this must work from CI too, and it proves the
    # certificate matches the NAME rather than the address.
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 12 --cacert "$CA" \
            --resolve "${h}.${BASE_DOMAIN}:443:${IP}" \
            "https://${h}.${BASE_DOMAIN}/" 2>/dev/null)"
    # ANY HTTP status proves TLS terminated and the backend answered. 404 and
    # 415 are the app being particular about paths and content types, which is
    # not a TLS problem. Only "000" -- curl could not connect or the handshake
    # failed -- is a failure here.
    if [[ -n "$code" && "$code" != "000" ]]; then
      ok "https://${h}.${BASE_DOMAIN} -> $code (TLS ok, cert valid for this name)"
    else
      warn "https://${h}.${BASE_DOMAIN} -> no TLS answer"; fail=1
    fi
  done
  rm -f "$CA"
  step "OIDC issuer"
  # StatefulSet, not Deployment. Querying the wrong kind returns empty and
  # reads as "issuer unset", which looks like the issuer move failed when it
  # had not been attempted.
  ISS="$(kubectl -n keycloak get statefulset keycloak -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_HOSTNAME")].value}' 2>/dev/null)"
  [[ "$ISS" == https://* ]] && ok "issuer is $ISS" || warn "issuer is still ${ISS:-unset}"
  [[ "$fail" -eq 0 ]] || exit 1
  exit 0
  ;;
esac

step "Certificate from the cluster CA"
kubectl get clusterissuer agentic-ca >/dev/null 2>&1 \
  || die "ClusterIssuer/agentic-ca not found — run 25-cluster-baseline.sh first"
kubectl apply -f "$LAB_ROOT/yaml/tls/certificate.yaml" >/dev/null \
  || die "could not request the certificate"
for _ in $(seq 1 30); do
  [[ "$(kubectl -n "$GW_NS" get certificate agentic-edge \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
  sleep 4
done
[[ "$(kubectl -n "$GW_NS" get certificate agentic-edge \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] \
  || { kubectl -n "$GW_NS" describe certificate agentic-edge >&2; die "certificate never became Ready"; }
ok "certificate issued, covering: $(echo $HOSTS | tr ' ' ',')"

step "HTTPS listener on the Gateway"
# Keep the HTTP listener. Removing it would break in-mesh callers that use the
# same hostnames over plain HTTP, which is deliberate (see the header).
kubectl -n "$GW_NS" patch gateway "$GW" --type=json -p='[
 {"op":"add","path":"/spec/listeners/-","value":{
   "name":"https","protocol":"HTTPS","port":443,
   "tls":{"mode":"Terminate","certificateRefs":[{"kind":"Secret","name":"agentic-edge-tls"}]},
   "allowedRoutes":{"namespaces":{"from":"All"}}}}]' >/dev/null 2>&1 \
  || kubectl -n "$GW_NS" get gateway "$GW" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | grep -q https \
  || die "could not add the HTTPS listener"
for _ in $(seq 1 30); do
  [[ "$(kubectl -n "$GW_NS" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]] && break
  sleep 5
done
ok "listener added: $(kubectl -n "$GW_NS" get gateway "$GW" -o jsonpath='{range .spec.listeners[*]}{.name}:{.port} {end}' 2>/dev/null)"

step "Distributing the CA to in-cluster OIDC clients"
# This is the unavoidable cost of a private CA, and GCD leaves no alternative:
# no Certificate Manager, no privateca, no public DNS zone for ACME. Once the
# issuer is https, every client that does OIDC discovery must trust the CA or it
# fails closed with "x509: certificate signed by unknown authority" -- which
# reads like a broken certificate and is really a missing trust anchor.
CA_PEM="$(kubectl -n "$GW_NS" get secret agentic-edge-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null)"
if [[ -n "$CA_PEM" ]]; then
  for ns in solo-enterprise agentregistry-system kagent; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    printf '%s' "$CA_PEM" > /tmp/agentic-ca.pem
    kubectl -n "$ns" create configmap agentic-ca --from-file=ca.crt=/tmp/agentic-ca.pem \
      --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 \
      && ok "CA available in $ns" || warn "could not put the CA in $ns"
  done
  rm -f /tmp/agentic-ca.pem
else
  warn "could not read the CA from the certificate secret"
fi

step "Moving the OIDC issuer to https"
# Keycloak stamps KC_HOSTNAME into every token's iss claim, and every client
# validates it, so this has to change everywhere at once. Two things make it
# safe here rather than a re-registration exercise: the realm's redirect URIs
# are wildcards, and KC_PROXY_HEADERS=xforwarded is already set so Keycloak
# honours the gateway's X-Forwarded-Proto.
ISSUER_SCHEME=https "$SD/30-keycloak.sh" >/dev/null 2>&1 \
  && ok "issuer is now https://keycloak.${BASE_DOMAIN}/realms/agentregistry" \
  || warn "could not re-run 30-keycloak.sh; the issuer is still http"

# 30-keycloak.sh points keycloak.$BASE_DOMAIN at Keycloak's OWN ClusterIP,
# because at that point in the chain the gateway does not exist yet.
# 80-ingress.sh later re-points it at the gateway. Re-running 30 on its own
# therefore silently undoes that, and every https call to the issuer then hits a
# pod with no TLS listener and fails the handshake -- which reads like a
# certificate problem and is not. Put the record back.
step "Re-pointing the issuer hostname at the gateway"
GW_IP="$(kubectl -n "$GW_NS" get svc "$GW" \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
if [[ -n "$GW_IP" ]]; then
  dns_upsert "keycloak.${BASE_DOMAIN}" "$GW_IP"
else
  warn "no gateway address; keycloak.${BASE_DOMAIN} still points at the Keycloak Service"
fi

step "Mounting the CA into the UI backend"
# Patched onto the Deployment rather than passed as helm values. The management
# chart's ui.backend.volumes is NOT an arbitrary volume list -- the frontend
# equivalent is a map of emptyDir sizes -- and feeding it a list renders invalid
# YAML: "could not find expected ':'" from the chart's own template. A strategic
# merge patch is honest about what it is doing and does not fight the chart.
#
# SSL_CERT_FILE is honoured by Go's crypto/x509, so this is enough to make the
# backend trust the issuer without rebuilding its image.
kubectl -n solo-enterprise patch deploy solo-enterprise-ui --type=strategic -p '{
  "spec":{"template":{"spec":{
    "volumes":[{"name":"agentic-ca","configMap":{"name":"agentic-ca"}}],
    "containers":[{"name":"ui-backend",
      "volumeMounts":[{"name":"agentic-ca","mountPath":"/etc/agentic-ca","readOnly":true}],
      "env":[{"name":"SSL_CERT_FILE","value":"/etc/agentic-ca/ca.crt"}]}]}}}}' >/dev/null 2>&1 \
  && ok "UI backend now trusts the internal CA" \
  || warn "could not patch the UI backend; it will fail OIDC discovery"
kubectl -n solo-enterprise rollout status deploy/solo-enterprise-ui --timeout=180s >/dev/null 2>&1 \
  && ok "UI ready" || warn "UI not ready yet; check: kubectl -n solo-enterprise logs deploy/solo-enterprise-ui -c ui-backend"

step "Restarting the other OIDC clients so they pick up the new issuer"
# They do OIDC discovery at STARTUP, so a config change alone is not enough.
for d in agentregistry-system/agentregistry-enterprise-server kagent/kagent-controller; do
  kubectl -n "${d%%/*}" rollout restart "deploy/${d##*/}" >/dev/null 2>&1 || true
done
ok "restarted; they rediscover on boot"

step "Done"
"$0" --verify || true
cat >&2 <<EOF

  Trust the CA so browsers stop warning:

    ./scripts/85-tls.sh --ca > /tmp/agentic-ca.crt
    # macOS:
    sudo security add-trusted-cert -d -r trustRoot \\
      -k /Library/Keychains/System.keychain /tmp/agentic-ca.crt

  Then: https://kagent.${BASE_DOMAIN}

EOF
