#!/usr/bin/env bash
# lib.sh — shared helpers for the GCD agentic platform chain.
# Ported from solo-demos/agentregistry-agentcore-kind/deploy/scripts/lib.sh with
# every kind-specific helper removed (no kind load, no host registry, no
# extraPortMappings, no localtest.me hostAlias bridge — a Cloud DNS private zone
# does that job here).

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LAB_ROOT/../.." && pwd)"
TOFU_DIR="$REPO_ROOT/infra/tofu"

# ── output ────────────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;34m▸ %s\033[0m\n' "$*" >&2; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*" >&2; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
log()   { printf '    %s\n' "$*" >&2; }
die()   { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
}

# ── environment ───────────────────────────────────────────────────────────────
load_env() {
  [[ -f "$REPO_ROOT/.env.local" ]] || die ".env.local not found at $REPO_ROOT"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env.local"
  : "${UNIVERSE_API_DOMAIN:?}" "${UNIVERSE_REGION:?}" "${PROJECT_ID:?}"

  # The gcs BACKEND has no universe_domain setting (only the google provider
  # does), so every `tofu` invocation — including a bare `tofu output` — fails
  # without this. tofu_out() is called from kube_context(), so forgetting it
  # makes every script die at its first kubectl call with no useful message.
  export GOOGLE_CLOUD_UNIVERSE_DOMAIN="$UNIVERSE_API_DOMAIN"

  # Written by 10-tofu.sh. Absent before the first apply, which is fine for
  # scripts that only need .env.local.
  if [[ -f "$LAB_ROOT/deploy/.env.tofu" ]]; then
    # shellcheck disable=SC1091
    source "$LAB_ROOT/deploy/.env.tofu"
  fi

  # Solo license keys and the LLM keys live outside this repo.
  if [[ -f "$HOME/code/solo/secrets/secrets-envs.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/code/solo/secrets/secrets-envs.sh" >/dev/null 2>&1 || true
  fi
}

# The single most expensive mistake in this repo is silently talking to public
# GCP. Every script that touches the cloud calls this first.
assert_universe() {
  local active
  active="$(gcloud config get-value universe_domain 2>/dev/null || true)"
  [[ "$active" == "$UNIVERSE_API_DOMAIN" ]] \
    || die "gcloud universe_domain is '${active:-unset}', expected '$UNIVERSE_API_DOMAIN'. Run scripts/gcd-auth.sh."
  gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 \
    || die "cannot reach project '$PROJECT_ID' — token expired? Run scripts/gcd-auth.sh."
}

tofu_out() { (cd "$TOFU_DIR" && tofu output -raw "$1" 2>/dev/null || true); }

# ── kubernetes ────────────────────────────────────────────────────────────────
# The context name gcloud writes for a GCD cluster. Derived, not assumed: the
# eu0: prefix makes the usual gke_<project>_<location>_<name> shape unsafe to
# hand-build, so read it back from kubeconfig instead.
kube_context() {
  local name="${CLUSTER_NAME:-}"
  [[ -n "$name" ]] || name="$(tofu_out cluster_name)"
  [[ -n "$name" ]] || die "no cluster name — run 10-tofu.sh apply first"
  kubectl config get-contexts -o name 2>/dev/null | grep -- "$name" | head -1
}

kc() {
  local ctx; ctx="$(kube_context)"
  [[ -n "$ctx" ]] || die "no kubeconfig context for the cluster — run: $(tofu_out get_credentials_command)"
  kubectl --context "$ctx" "$@"
}

wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-180s}"
  kc -n "$ns" rollout status "$kind/$name" --timeout="$timeout"
}

# ── secrets, the GCD way ──────────────────────────────────────────────────────
# There is no Secret Manager in GCD, and GKE here does not support
# application-layer Secret encryption either, so a plaintext value would sit
# unencrypted in etcd. Envelope-encrypt with Cloud KMS and store the ciphertext.
# This protects the value in git and in our own storage; it does NOT protect it
# in etcd. Say so when asked.
kms_encrypt() {
  local plaintext="$1"
  : "${KMS_ENVELOPE_KEY:?KMS_ENVELOPE_KEY not set — run 10-tofu.sh apply}"
  printf '%s' "$plaintext" | gcloud kms encrypt \
    --key "$KMS_ENVELOPE_KEY" \
    --plaintext-file=- --ciphertext-file=- \
    --project "$PROJECT_ID" | base64
}

kms_decrypt() {
  local ciphertext_b64="$1"
  : "${KMS_ENVELOPE_KEY:?}"
  printf '%s' "$ciphertext_b64" | base64 -d | gcloud kms decrypt \
    --key "$KMS_ENVELOPE_KEY" \
    --ciphertext-file=- --plaintext-file=- \
    --project "$PROJECT_ID"
}

# ── private DNS ───────────────────────────────────────────────────────────────
# The kind lab bridged the OIDC issuer hostname into the cluster with a
# hostAlias on every consuming pod. Here a Cloud DNS PRIVATE zone does it
# properly, so one issuer string works in the browser and in the pods.
#
# Ordering matters though. kagent, the Enterprise UI and AgentRegistry all do
# OIDC discovery at startup, and they install BEFORE the ingress gateway exists.
# So 30-keycloak.sh points the record at Keycloak's ClusterIP (pods can route to
# a ClusterIP), and 80-ingress.sh re-points it at the gateway's internal address
# once that exists. Same name throughout, so no token ever has a stale iss.
dns_upsert() {
  local fqdn="$1" ip="$2" zone="${PRIVATE_DNS_ZONE_NAME:-}"
  [[ -n "$zone" ]] || zone="$(cd "$TOFU_DIR" && tofu output -raw private_dns_zone_name 2>/dev/null || true)"
  [[ -n "$zone" ]] || { warn "no private DNS zone — skipping record $fqdn"; return 0; }
  [[ "$fqdn" == *. ]] || fqdn="${fqdn}."

  local existing
  existing="$(gcloud dns record-sets list --zone "$zone" --name "$fqdn" --type A     --project "$PROJECT_ID" --format='value(rrdatas[0])' 2>/dev/null || true)"

  if [[ "$existing" == "$ip" ]]; then
    log "dns $fqdn already -> $ip"
  elif [[ -n "$existing" ]]; then
    gcloud dns record-sets update "$fqdn" --type A --ttl 60 --rrdatas "$ip" \
      --zone "$zone" --project "$PROJECT_ID" >/dev/null
    ok "dns $fqdn re-pointed $existing -> $ip"
  else
    gcloud dns record-sets create "$fqdn" --type A --ttl 60 --rrdatas "$ip" \
      --zone "$zone" --project "$PROJECT_ID" >/dev/null
    ok "dns $fqdn -> $ip"
  fi
}

# `gcloud auth configure-docker <host>` does NOT work for a GCD Artifact
# Registry host: it warns "is not a supported registry", writes no credHelpers
# entry, and the push then fails with a permissions error that sends you to IAM.
# See feedback/google/05. Basic auth with an access token works.
ar_docker_login() {
  local host="$1"
  gcloud auth print-access-token 2>/dev/null \
    | docker login -u oauth2accesstoken --password-stdin "$host" >/dev/null 2>&1 \
    && ok "docker authenticated to $host" \
    || die "could not authenticate docker to $host"
}

# A GCD session lasts roughly 45 minutes and there is no service-account or
# refresh path for a human principal, so every long-running script will hit an
# expired token eventually. The failure surfaces as a gke-gcloud-auth-plugin
# error on an unrelated kubectl call, which reads like the resource is missing.
# Call this before any "not found" diagnosis so the real cause is named.
assert_kube_reachable() {
  kubectl version --request-timeout=10s >/dev/null 2>&1 && return 0
  die "cannot reach the cluster. The GCD session has most likely expired (~45 min).
    Re-authenticate, then re-run:  ./scripts/gcd-auth.sh"
}

# ── evidence ──────────────────────────────────────────────────────────────────
# Findings are the most valuable output of this repo, so record verbatim.
evidence() {
  local slug="$1"; shift
  local out="$REPO_ROOT/feedback/google/evidence/berlin-${slug}-$(date -u +%Y-%m-%d).txt"
  mkdir -p "$(dirname "$out")"
  {
    printf '\n=== %s\n=== $ %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
  } >>"$out"
  "$@" >>"$out" 2>&1
  local rc=$?
  printf '%s\n' "$out"
  return $rc
}
