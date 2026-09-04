#!/usr/bin/env bash
# 85-edge.sh — apply the Tier 1 edge (stage=edge) once agentgateway exists.
#
# Runs last in Phase 1 because the regional external ALB's backend service
# needs the zonal NEGs that only come into being when agentgateway's Gateway
# Service is created with the cloud.google.com/neg annotation. This script
# reads that annotation, turns it into the tofu -var, and applies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl jq tofu
load_env
assert_universe

AGW_NS="${AGW_NS:-agentgateway-system}"
GW_NAME="${GW_NAME:-agentgateway-proxy}"

step "finding the Gateway Service for $GW_NAME in $AGW_NS"
GW_SVC="$(kc -n "$AGW_NS" get svc -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$GW_SVC" ]] || die "no Service for Gateway '$GW_NAME' in '$AGW_NS' — run 70-agentgateway.sh and 80-ingress.sh first"
ok "service: $GW_SVC"

# The NEG annotation is what GKE writes once it has created zonal NEGs. If it
# is missing, 80-ingress.sh did not annotate the Gateway Service — the edge
# cannot be wired without it.
step "reading neg-status"
NEG_STATUS="$(kc -n "$AGW_NS" get svc "$GW_SVC" \
  -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' 2>/dev/null || true)"
if [[ -z "$NEG_STATUS" ]]; then
  warn "no cloud.google.com/neg-status annotation on svc/$GW_SVC"
  warn "annotate the Gateway Service and wait, e.g.:"
  warn "  kubectl -n $AGW_NS annotate svc $GW_SVC 'cloud.google.com/neg={\"exposed_ports\":{\"80\":{}}}'"
  die "cannot wire the edge without NEGs"
fi
log "$NEG_STATUS"

# neg-status looks like: {"network_endpoint_groups":{"80":"k8s1-abc..."},"zones":["...-a","...-b"]}
NEG_NAME="$(jq -r '.network_endpoint_groups | to_entries[0].value' <<<"$NEG_STATUS")"
mapfile -t ZONES < <(jq -r '.zones[]' <<<"$NEG_STATUS")
[[ -n "$NEG_NAME" && ${#ZONES[@]} -gt 0 ]] || die "could not parse neg-status"
ok "NEG '$NEG_NAME' in ${#ZONES[@]} zone(s): ${ZONES[*]}"

# Build the tofu -var as HCL: [{zone=..., name=...}, ...]
NEGS_HCL="["
for z in "${ZONES[@]}"; do
  NEGS_HCL+="{zone=\"$z\",name=\"$NEG_NAME\"},"
done
NEGS_HCL="${NEGS_HCL%,}]"

# ── BYO TLS. No Certificate Manager, no ACME, so the leaf is hand-made. ──────
TLS_ARGS=()
CERT_DIR="$LAB_ROOT/deploy/tls"
if [[ -f "$CERT_DIR/tls.crt" && -f "$CERT_DIR/tls.key" ]]; then
  ok "using BYO cert from $CERT_DIR"
  TLS_ARGS=(-var "tls_cert_pem=$(cat "$CERT_DIR/tls.crt")" -var "tls_key_pem=$(cat "$CERT_DIR/tls.key")")
else
  warn "no cert at $CERT_DIR/tls.{crt,key} — the edge will serve HTTP on :80"
  warn "GCD has no Certificate Manager, no privateca and no public Cloud DNS zone,"
  warn "so ACME is impossible by either challenge type. Generate a self-signed leaf with:"
  warn "  mkdir -p $CERT_DIR && openssl req -x509 -newkey rsa:2048 -nodes -days 365 \\"
  warn "    -subj '/CN=agentic.eu0.internal' -keyout $CERT_DIR/tls.key -out $CERT_DIR/tls.crt"
fi

step "tofu apply stage=edge"
cd "$TOFU_DIR"
tofu apply -input=false \
  -var-file="profiles/${TOFU_PROFILE:-gcd-autopilot}.tfvars" \
  -var "stage=edge" \
  -var "gateway_negs=$NEGS_HCL" \
  "${TLS_ARGS[@]}"

INGRESS_IP="$(tofu output -raw ingress_ip 2>/dev/null || true)"
ARMOR="$(tofu output -raw armor_policy 2>/dev/null || true)"

cat >&2 <<EOF

  Tier 1 edge is up.
    external IP     ${INGRESS_IP:-?}
    Cloud Armor     ${ARMOR:-?}  (Standard tier — Enterprise is unavailable in GCD)
    load balancer   regional external ALB (no global or classic LBs exist here)

  Google's edge protects the HTTP. agentgateway behind it protects the agent:
  JWT, MCP tool authorization, LLM policy, rate limits, budgets, audit. That is
  the whole architecture argument, and it is now real rather than asserted.

  Point your hosts file at it while there is no public DNS zone:
    ${INGRESS_IP:-<ip>}  keycloak.agentic.eu0.internal agentregistry.agentic.eu0.internal kagent.agentic.eu0.internal
EOF
