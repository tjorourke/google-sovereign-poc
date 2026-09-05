#!/usr/bin/env bash
# 56-ar-push-agent.sh — build an agent, catalogue it in AgentRegistry, and let
# AgentRegistry deploy it onto kagent. Idempotent: safe to re-run.
#
# This is the governance flow, and the order matters. Nothing here runs kubectl
# against kagent. The registry is the only writer: it resolves the catalogued
# Agent and MCPServer records, then creates the kagent Agent CR, the
# RemoteMCPServer and the workload itself using its own ServiceAccount. The
# catalogue is not a document describing what is deployed, it is what deploys.
#
# Berlin-specific notes:
#   * The image goes to the in-universe Artifact Registry. Docker cannot use the
#     gcloud credential helper against this host (feedback/google/05), so we log
#     in with an access token, and we build --platform linux/amd64 because GCD
#     has no Arm compute.
#   * The agent's model is the self-hosted Qwen in the cluster and its tools are
#     reached through agentgateway. Neither is baked into the image: both arrive
#     as deploy-time env on the AR Deployment, which is what makes the same image
#     portable to another runtime.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
assert_universe
kube_context
assert_kube_reachable

AGENT_DIR="$LAB_ROOT/agentregistry/sovereignagent"
CATALOG="$LAB_ROOT/agentregistry/catalog"
IMAGE="${AR_PREFIX}/sovereignagent:${AGENT_TAG:-0.1.0}"

require docker kubectl python3
# shellcheck source=55-arctl-connect.sh
# 55 is sourced, so it returns rather than exiting (it has to be safe to source
# into an interactive shell). Check the return value here instead.
source "$SD/55-arctl-connect.sh"
[[ "${_ARCTL_RC:-1}" -eq 0 ]] || die "could not connect arctl to AgentRegistry"

step "Build the agent image and push it into the universe"
ar_docker_login "$AR_HOST"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  log "SKIP_BUILD=1, reusing $IMAGE"
else
  arctl build "$AGENT_DIR" --push --platform linux/amd64 --image "$IMAGE" \
    || die "arctl build failed"
  ok "pushed $IMAGE"
fi

step "Catalogue the tool server and the agent"
# Applied with arctl, not kubectl: AgentRegistry records live in Postgres, and
# it ships no CRDs at all.
arctl apply -f "$CATALOG/mcpserver.yaml"   || die "could not catalogue the MCP server"
arctl apply -f "$AGENT_DIR/agent.yaml"     || die "could not catalogue the agent"

step "Let AgentRegistry push the agent onto kagent"
# AgentRegistry keeps its state in Cloud SQL, which OUTLIVES the cluster. After
# a cluster rebuild the Deployment record is still there, still marked
# "deploying" against a cluster that no longer exists, so `arctl apply` reports
# it "unchanged" and reconciles nothing -- the kagent CRs are never created and
# the wait below times out with "AgentRegistry created no workload", which
# sounds like a registry fault rather than stale state.
#
# If a record exists but its workload does not, recreate the record. Deleting
# only the record is safe: the catalogue Agent and MCPServer entries, which are
# the governance data worth keeping, are separate objects.
if arctl get deployments 2>/dev/null | grep -q 'sovereignagent-kagent'; then
  if ! kubectl -n agentregistry-system get deploy 2>/dev/null | grep -q sovereignagent; then
    warn "a Deployment record exists but its workload does not — this is the"
    warn "registry's Cloud SQL state surviving a cluster rebuild. Recreating it."
    arctl delete deployment sovereignagent-kagent >/dev/null 2>&1 || true
    sleep 3
  fi
fi
arctl apply -f "$CATALOG/deployment.yaml"  || die "could not create the AR Deployment"

step "Wait for the workload the registry created"
# AR derives the object names, so discover them by label rather than assuming.
DEPLOY=""
for _ in $(seq 1 60); do
  DEPLOY="$(kubectl -n agentregistry-system get deploy -o name 2>/dev/null \
            | grep -m1 sovereignagent || true)"
  [[ -n "$DEPLOY" ]] && break
  sleep 5
done
[[ -n "$DEPLOY" ]] || die "AgentRegistry created no workload.
    The registry's Deployment record and the cluster disagree. Inspect with:
      arctl get deployments -o yaml
    If a record exists while the workload does not, the record is stale from a
    previous cluster; delete it and re-run:
      arctl delete deployment sovereignagent-kagent"
kubectl -n agentregistry-system rollout status "$DEPLOY" --timeout=300s \
  || die "the pushed agent did not become ready"

step "What the registry created, without anyone running kubectl"
kubectl get agents.kagent.dev -A            | grep -E 'NAME|sovereignagent' || true
kubectl get remotemcpservers.kagent.dev -A  | grep -E 'NAME|sovereign-tools'       || true
ok "AgentRegistry deployed the agent onto kagent"

step "Ask it something that requires the governed tool"
"$SD/57-ar-ask.sh" "Add 17 and 25 using your sum tool."
