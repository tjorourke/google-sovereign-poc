#!/usr/bin/env bash
# deploy.sh — TrustUsBank AG: SEPA Instant fraud triage, three agents, two MCP
# servers, governed end to end.
#
#   ./scripts/deploy.sh              deploy everything
#   ./scripts/deploy.sh --ambient    only item 1 (put the older namespaces in the mesh)
#
# Assumes the main lab is already up: poc/2026-09-agentic-platform provides the
# cluster, ambient mesh, Keycloak, the gateway, TLS and the self-hosted model.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$SD/.." && pwd)"
PLATFORM="$(cd "$LAB/../2026-09-agentic-platform" && pwd)"
REPO="$(cd "$LAB/../.." && pwd)"
NS=trustusbank

# Same isolated kubeconfig as the platform lab. ~/.kube/config is shared with
# every kind cluster on this laptop and gets clobbered mid-run.
export KUBECONFIG="${GCD_KUBECONFIG:-$PLATFORM/deploy/.kubeconfig}"
[[ -f "$REPO/.env.local" ]] && { set -a; source "$REPO/.env.local"; set +a; }
export GOOGLE_CLOUD_UNIVERSE_DOMAIN="${UNIVERSE_API_DOMAIN:-}"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
ylw(){ printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
hdr(){ printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
log(){ printf '    %s\n' "$*"; }
die(){ printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

timeout 25 kubectl version --request-timeout=10s >/dev/null 2>&1 \
  || die "cannot reach the cluster. Re-authenticate: $REPO/scripts/gcd-auth-assist.sh login"

# ── item 1: put the older namespaces into the ambient mesh ──────────────────
# agentregistry-system and mcp were outside the mesh, so the AgentRegistry-
# deployed agent had neither a gateway policy nor an mTLS identity -- the one
# workload in the stack with no governance at all. Labelling is not enough on
# its own: ztunnel only captures a pod at admission, so existing pods have to be
# recreated before they get an identity.
hdr "Item 1 — putting agentregistry-system and mcp into the ambient mesh"
for ans in agentregistry-system mcp; do
  kubectl get ns "$ans" >/dev/null 2>&1 || { ylw "$ans absent, skipping"; continue; }
  cur="$(kubectl get ns "$ans" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)"
  if [[ "$cur" == ambient ]]; then grn "$ans already ambient"; continue; fi
  kubectl label ns "$ans" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1 \
    && grn "$ans labelled ambient" || { ylw "could not label $ans"; continue; }
  for d in $(kubectl -n "$ans" get deploy -o name 2>/dev/null); do
    kubectl -n "$ans" rollout restart "$d" >/dev/null 2>&1 || true
  done
  log "pods restarting so ztunnel captures them"
done
for ans in agentregistry-system mcp; do
  kubectl get ns "$ans" >/dev/null 2>&1 || continue
  for d in $(kubectl -n "$ans" get deploy -o name 2>/dev/null); do
    kubectl -n "$ans" rollout status "$d" --timeout=240s >/dev/null 2>&1 \
      && grn "${d#deployment.apps/} ready" || ylw "${d#deployment.apps/} slow to roll"
  done
done
[[ "${1:-}" == "--ambient" ]] && { hdr "DONE (item 1 only)"; exit 0; }

# ── namespace ───────────────────────────────────────────────────────────────
hdr "Namespace"
kubectl apply -f "$LAB/yaml/00-namespace.yaml" >/dev/null || die "namespace failed"
grn "$NS (ambient)"

# ── the MCP server source, and the pull secret ──────────────────────────────
# The servers are our own Python mounted onto an image that is already in the
# in-universe registry, so there is nothing to build and nothing to mirror.
hdr "MCP server source"
kubectl -n "$NS" create configmap trustusbank-mcp-src \
  --from-file="$LAB/mcp/core_banking.py" \
  --from-file="$LAB/mcp/compliance.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  && grn "configmap trustusbank-mcp-src (core_banking.py, compliance.py)" \
  || die "could not create the source configmap"

# The node credential provider returns 403 for this host even with
# artifactregistry.reader granted, so an explicit pull secret is required. The
# token is short-lived, hence minting it here rather than reusing an old one.
hdr "Image pull secret"
AR_HOST="$(kubectl -n mcp get deploy everything-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d/ -f1)"
AR_HOST="${AR_HOST:-docker.pkg-berlin-build0.goog}"
kubectl -n "$NS" create secret docker-registry ar-pull \
  --docker-server="$AR_HOST" \
  --docker-username=oauth2accesstoken \
  --docker-password="$(gcloud auth print-access-token 2>/dev/null)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  && grn "secret/ar-pull for $AR_HOST" || die "could not create the pull secret"

# ── MCP servers ─────────────────────────────────────────────────────────────
hdr "MCP servers (KMCP provisions the deployment, service and waypoint)"
kubectl apply -f "$LAB/yaml/10-mcp-servers.yaml" >/dev/null || die "MCPServers failed"
for m in core-banking compliance; do
  for _ in $(seq 1 40); do
    r="$(kubectl -n "$NS" get mcpserver "$m" \
         -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$r" == "True" ]] && break
    sleep 6
  done
  [[ "$r" == "True" ]] && grn "MCPServer $m Ready" \
    || ylw "MCPServer $m not Ready yet — kubectl -n $NS describe mcpserver $m"
done

# The waypoint hop has to be allowed before discovery will work at all; see the
# comment in 31-waypoint-hop.yaml.
hdr "Waypoint hop"
kubectl apply -f "$LAB/yaml/31-waypoint-hop.yaml" >/dev/null \
  && grn "waypoint and controller identities allowed to reach both servers" \
  || ylw "could not apply the waypoint hop policy"

# ── model config ────────────────────────────────────────────────────────────
# ModelConfig and its API-key secret are both namespace-scoped, and an Agent
# resolves modelConfig by bare name in its OWN namespace, so both have to exist
# here before the agents will compile.
hdr "ModelConfig and model credential"
kubectl -n kagent get secret kagent-openai -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':'kagent-openai','namespace':'trustusbank'}
d.pop('status',None)
print(json.dumps(d))" 2>/dev/null \
  | kubectl apply -f - >/dev/null 2>&1 \
  && grn "secret/kagent-openai copied from kagent" \
  || ylw "could not copy the model credential secret"
kubectl apply -f "$LAB/yaml/05-modelconfig.yaml" >/dev/null \
  && grn "ModelConfig selfhosted -> Qwen2.5-3B-Instruct via agentgateway" \
  || die "modelconfig failed"

# ── agents, then the policies that constrain them ───────────────────────────
hdr "Agents"
kubectl apply -f "$LAB/yaml/20-agents.yaml" >/dev/null || die "agents failed"
for a in betrugsanalyse sanktionspruefung zahlungstriage; do
  for _ in $(seq 1 40); do
    r="$(kubectl -n "$NS" get agent "$a" \
         -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$r" == "True" ]] && break
    sleep 6
  done
  [[ "$r" == "True" ]] && grn "Agent $a Ready" || ylw "Agent $a not Ready yet"
done

# If this namespace previously ran per-AGENT waypoints, the Services keep an
# istio.io/use-waypoint label pointing at a waypoint that no longer exists, and
# traffic to them breaks. Removing the label from the Agent does not clean the
# Service, so do it here -- this is what makes re-running safe after the
# topology change described in yaml/15-waypoint.yaml.
hdr "Clearing stale per-agent waypoint pins"
for a in betrugsanalyse sanktionspruefung zahlungstriage; do
  cur="$(kubectl -n "$NS" get svc "$a" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null)"
  [[ -n "$cur" ]] || continue
  kubectl -n "$NS" label svc "$a" istio.io/use-waypoint- >/dev/null 2>&1 \
    && grn "svc/$a unpinned from $cur"
done
for g in $(kubectl -n "$NS" get gateway --no-headers 2>/dev/null | awk '/^agent-/{print $1}'); do
  kubectl -n "$NS" delete gateway "$g" >/dev/null 2>&1 && grn "removed redundant per-agent waypoint $g"
done

hdr "AccessPolicies (the controls)"
kubectl apply -f "$LAB/yaml/30-accesspolicies.yaml" >/dev/null || die "accesspolicies failed"
kubectl -n "$NS" get accesspolicies.policy.kagent-enterprise.solo.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.conditions[0].status --no-headers 2>/dev/null \
  | sed 's/^/    /'
grn "3 policies applied"

hdr "Item 2 — A2A published through agentgateway"
kubectl apply -f "$LAB/yaml/40-a2a-edge.yaml" >/dev/null \
  && grn "a2a backend, route and L4 caller restriction applied" \
  || ylw "could not apply the a2a edge"

# The agents cache tool discovery at startup, so they must be restarted AFTER
# the policies exist or they hold the pre-policy tool list.
hdr "Restarting agents so they rediscover under policy"
for a in betrugsanalyse sanktionspruefung zahlungstriage; do
  kubectl -n "$NS" rollout restart "deploy/$a" >/dev/null 2>&1 || true
done
for a in betrugsanalyse sanktionspruefung zahlungstriage; do
  kubectl -n "$NS" rollout status "deploy/$a" --timeout=300s >/dev/null 2>&1 \
    && grn "$a rolled out" || ylw "$a rollout slow"
done

hdr "DONE"
cat <<EOF

  Run the scenario:   ./scripts/demo.sh
  Prove the controls: ./scripts/health.sh

EOF
