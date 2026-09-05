#!/usr/bin/env bash
# 10-tofu.sh — provision the infrastructure, then write .env.tofu for the rest
# of the chain to source. Same pattern as solo-demos/agentgw-agentcore-multi-account-kind.
#
#   ./10-tofu.sh plan      show the diff (default)
#   ./10-tofu.sh apply     create it
#   ./10-tofu.sh destroy   tear it down
#
# State lives in a GCS bucket inside the universe. Create it once by hand first:
#   gcloud storage buckets create "gs://${PROJECT_SHORT}-tofu-state" \
#     --project "$PROJECT_ID" --location "$UNIVERSE_REGION" --uniform-bucket-level-access
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOFU_DIR="$REPO_ROOT/infra/tofu"
ACTION="${1:-plan}"

cd "$REPO_ROOT"
[[ -f .env.local ]] || { echo "error: .env.local not found." >&2; exit 1; }
# shellcheck disable=SC1091
source .env.local
: "${UNIVERSE_API_DOMAIN:?}" "${UNIVERSE_REGION:?}" "${PROJECT_ID:?}" "${PROJECT_SHORT:?}"

PROFILE="${TOFU_PROFILE:-gcd-autopilot}"
STATE_BUCKET="${TOFU_STATE_BUCKET:-${PROJECT_SHORT}-tofu-state}"

# Guard: the most expensive mistake in this repo is talking to public GCP.
ACTIVE="$(gcloud config get-value universe_domain 2>/dev/null || true)"
if [[ "$ACTIVE" != "$UNIVERSE_API_DOMAIN" ]]; then
  echo "error: gcloud universe_domain is '${ACTIVE:-unset}', expected '$UNIVERSE_API_DOMAIN'." >&2
  echo "       run scripts/gcd-auth.sh first." >&2
  exit 1
fi

# ADC does not inherit the quota project, and Terraform/OpenTofu need it.
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null 2>&1 || \
  echo "warn: could not set the ADC quota project; expect 'API not enabled' style errors" >&2

# ── the GCS backend has no universe_domain setting ──────────────────────────
# The `google` PROVIDER takes universe_domain as an argument. The `gcs` BACKEND
# does not — it defaults to googleapis.com and then refuses to run because the
# credentials say otherwise:
#
#   Error: Failed to get existing workspaces: querying Cloud Storage failed:
#   ... the configured universe domain ("googleapis.com") does not match the
#   universe domain found in the credentials ("apis-berlin-build0.goog")
#
# The only lever is the client-library environment variable, so export it for
# every tofu invocation. Without it `tofu init` fails before it reads a single
# resource, which makes it look like a credentials problem rather than a
# backend one.
export GOOGLE_CLOUD_UNIVERSE_DOMAIN="$UNIVERSE_API_DOMAIN"

cd "$TOFU_DIR"
tofu init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=agentic/${PROFILE}"

VARFILE="profiles/${PROFILE}.tfvars"
[[ -f "$VARFILE" ]] || { echo "error: no $VARFILE" >&2; exit 1; }

# ── JIT service agents ─────────────────────────────────────────────────────────
# In GCD, service agents are provisioned just-in-time on first resource
# creation, NOT when the API is enabled (/kubernetes-engine/docs/tpc-differences).
# Every CMEK binding therefore needs its consuming service's agent to already
# exist and hold cryptoKeyEncrypterDecrypter on the key. Create them explicitly
# between `foundation` and `platform`, and grant them. If a CMEK resource 400s
# about the key, this is the step that was skipped.
# Verified live 2026-09-03. Three things bit us, all worth knowing:
#
#  1. `gcloud beta services identity create` needs the beta component, which is
#     not installed and cannot be auto-accepted with --quiet (the prompt is the
#     component install, not the command). Use the REST call below instead.
#  2. BigQuery does NOT support generateServiceIdentity — it returns
#     "Request contains an invalid argument" — and its CMEK agent follows a
#     different naming pattern entirely: bq-<NUM>@bigquery-encryption.<prefix>-system...
#     rather than service-<NUM>@gcp-sa-<svc>...
#  3. Cloud Storage's generateServiceIdentity response carries no email. Get it
#     from `gcloud storage service-agent` instead.
#
# And separately from CMEK: the GKE service agent is JIT-created WITHOUT its
# default roles, so cluster creation fails with
#   Error 403: Required 'compute.subnetworks.get' permission for ... subnetworks/agentic-nodes
# until roles/container.serviceAgent is granted to it explicitly. The GKE
# differences page warns about this; it is easy to read past.
CMEK_SERVICES=(
  sqladmin.googleapis.com
  artifactregistry.googleapis.com
  storage.googleapis.com
  logging.googleapis.com
  container.googleapis.com
  pubsub.googleapis.com
)
PROJECT_NUMBER="${PROJECT_NUMBER:-560780937444745}"

# Emitted into this file by create_service_agents so grant_kms_to_agents can
# reuse them without a second round of API calls.
declare -a AGENT_EMAILS=()
# Log buckets tofu manages; used by undelete_log_buckets above.
declare -a LOG_BUCKETS=("agentic-audit")

create_service_agents() {
  echo "==> creating JIT service agents (GCD provisions these on first use, not on API enable)"
  local token; token="$(gcloud auth print-access-token)"
  for svc in "${CMEK_SERVICES[@]}"; do
    printf '  %-40s ' "$svc"
    local email
    email="$(curl -sS -X POST -H "Authorization: Bearer ${token}" -H "Content-Length: 0" \
      "https://serviceusage.${UNIVERSE_API_DOMAIN}/v1beta1/projects/${PROJECT_NUMBER}/services/${svc}:generateServiceIdentity" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response",{}).get("email",""))' 2>/dev/null)"
    # Cloud Storage returns no email from that call; ask the GA command.
    if [[ -z "$email" && "$svc" == storage.googleapis.com ]]; then
      email="$(gcloud storage service-agent --project "$PROJECT_ID" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ -n "$email" ]]; then
      AGENT_EMAILS+=("$email"); echo "$email"
    else
      echo "(no email returned)"
    fi
  done
  # BigQuery has no generateServiceIdentity and a different naming pattern.
  # macOS ships bash 3.2, which has no negative array subscripts, so ${a[-1]}
  # fails with "bad array subscript" under set -u. Name the value instead.
  local bq_agent="bq-${PROJECT_NUMBER}@bigquery-encryption.${UNIVERSE_PREFIX}-system.iam.gserviceaccount.com"
  AGENT_EMAILS+=("$bq_agent")
  printf '  %-40s %s\n' "bigquery (derived)" "$bq_agent"
}

# Cloud Logging buckets are SOFT-deleted: a destroy leaves them in
# DELETE_REQUESTED for 7 days, and tofu then cannot recreate or modify one:
#   Error 400: Buckets must be in an ACTIVE state to be modified
# The name is deterministic, so a rebuild inside that window always collides.
# Undelete rather than wait, and treat "not found" as fine (first-ever apply).
undelete_log_buckets() {
  local b
  for b in "${LOG_BUCKETS[@]:-}"; do
    [[ -n "$b" ]] || continue
    local state
    state="$(gcloud logging buckets describe "$b" \
      --location="$UNIVERSE_REGION" --project="$PROJECT_ID" \
      --format='value(lifecycleState)' 2>/dev/null || true)"
    if [[ "$state" == "DELETE_REQUESTED" ]]; then
      echo "==> undeleting soft-deleted log bucket $b"
      gcloud logging buckets undelete "$b" \
        --location="$UNIVERSE_REGION" --project="$PROJECT_ID" >/dev/null 2>&1 \
        && echo "  ok, now ACTIVE" \
        || echo "  FAILED — the platform stage will 400 on this bucket"
    fi
  done
}

# The GKE service agent is created without its default roles, so the cluster
# cannot read the subnet we just made. Grant it before stage=platform.
grant_gke_service_agent() {
  local sa="service-${PROJECT_NUMBER}@container-engine-robot.${UNIVERSE_PREFIX}-system.iam.gserviceaccount.com"
  echo "==> granting roles/container.serviceAgent to $sa"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa}" --role=roles/container.serviceAgent \
    --condition=None >/dev/null 2>&1 && echo "  ok" || echo "  FAILED — cluster creation will 403 on compute.subnetworks.get"
}

# Project-level org policies need this, and Organisation Administrator alone is
# not enough: the apply 403s on every google_project_organization_policy.
grant_org_policy_admin() {
  local pool="principalSet://iam.googleapis.com/locations/global/workforcePools/${WORKFORCE_POOL}/*"
  echo "==> granting roles/orgpolicy.policyAdmin to the workforce pool"
  gcloud organizations add-iam-policy-binding "$ORG_NUMBER" \
    --member="$pool" --role=roles/orgpolicy.policyAdmin --condition=None >/dev/null 2>&1 \
    && echo "  ok" || echo "  FAILED — org policy resources will 403"
}

grant_kms_to_agents() {
  local ring
  ring="$(cd "$TOFU_DIR" && tofu output -raw kms_key_ring 2>/dev/null || true)"
  [[ -n "$ring" ]] || ring="$(gcloud kms keyrings list --location "$UNIVERSE_REGION" \
    --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | head -1)"
  [[ -n "$ring" ]] || { echo "warn: no key ring; run stage=foundation first" >&2; return; }
  echo "==> granting cryptoKeyEncrypterDecrypter on $(basename "$ring")"
  # Every agent on every key. Over-broad for a POC and deliberately simple: a
  # customer template would scope one agent to one key, which is why the module
  # creates them separately.
  local keys; keys="$(gcloud kms keys list --keyring "$(basename "$ring")" \
    --location "$UNIVERSE_REGION" --project "$PROJECT_ID" --format='value(name)' 2>/dev/null)"
  for email in "${AGENT_EMAILS[@]}"; do
    [[ -n "$email" ]] || continue
    printf '  %-74s ' "$email"
    local n=0
    while read -r key; do
      [[ -n "$key" ]] || continue
      gcloud kms keys add-iam-policy-binding "$key" \
        --member="serviceAccount:${email}" \
        --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
        --project "$PROJECT_ID" >/dev/null 2>&1 && n=$((n+1))
    done <<<"$keys"
    echo "${n} key(s)"
  done
}

apply_stage() {
  local stage="$1"
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  stage: $stage"
  echo "════════════════════════════════════════════════════════════════"
  # -auto-approve is required: -input=false cannot prompt, so apply would
  # otherwise abort. This script (and the plan you ran first) is the gate.
  #
  # TOFU_REPLACE forces one resource to be destroyed and recreated in the same
  # apply. It exists so a cluster teardown reuses the var-file and backend
  # handling above rather than a hand-rolled `tofu apply` elsewhere, which is
  # how it was first attempted and immediately failed on unset root variables.
  # Prefer this to a full destroy: Cloud SQL, KMS (prevent_destroy), the network
  # and the buckets take far longer to rebuild than the cluster and none of them
  # hold in-cluster state.
  # Do NOT collect this in an array: bash 3.2, the macOS default and what
  # `env bash` resolves to here, errors on "${arr[@]}" for an EMPTY array under
  # set -u -- which is exactly the no-replace case.
  if [[ -n "${TOFU_REPLACE:-}" ]]; then
    tofu apply -input=false -auto-approve -var-file="$VARFILE" \
      -var "stage=${stage}" -replace="$TOFU_REPLACE"
  else
    tofu apply -input=false -auto-approve -var-file="$VARFILE" -var "stage=${stage}"
  fi
}

case "$ACTION" in
  plan)
    tofu plan -input=false -var-file="$VARFILE" -var "stage=${TOFU_STAGE:-platform}"
    exit 0
    ;;
  apply)
    # Staged on purpose — see PLAN.md phase 1. A single apply across KMS, a
    # cluster and CMEK bindings is undebuggable on an unproven cloud.
    #
    # BUT the stages are EXCLUSIVE, not cumulative: platform resources are
    # gated on var.stage, so `-var stage=foundation` means "platform resources
    # are no longer wanted" and plans to DESTROY them. On a live deployment
    # that is:
    #   Plan: 0 to add, 0 to change, 8 to destroy
    # including google_sql_database_instance.pg and both application databases.
    # It only ever looked safe because Postgres refuses to drop a database that
    # has connections, so the destroy failed rather than succeeded. Re-running
    # `apply` against a deployed environment must never be able to do that.
    #
    # Once the platform stage exists in state, foundation is already satisfied
    # (platform is a superset: it plans 0 destroys), so skip straight to it.
    # Fail SAFE. If the state cannot be read we must NOT run a stage whose
    # only possible effect on a live deployment is destruction, so anything
    # other than a confidently-empty state skips it. The first version of this
    # guard hid the state-list error in 2>/dev/null and silently fell through
    # to the destructive branch.
    STATE_LIST="$(tofu state list 2>&1)"; STATE_RC=$?
    if [[ "$STATE_RC" -ne 0 ]]; then
      echo "==> cannot read tofu state (exit $STATE_RC); NOT running the"
      echo "    foundation stage, which would plan to destroy platform"
      echo "    resources. First lines of the error:"
      printf '%s\n' "$STATE_LIST" | head -3 | sed 's/^/      /'
    elif printf '%s\n' "$STATE_LIST" | grep -q '^module\.cloudsql'; then
      echo "==> platform resources already in state; skipping the foundation"
      echo "    stage, which would plan to DESTROY them (see comment above)."
    elif [[ -z "${STATE_LIST//[[:space:]]/}" ]]; then
      echo "==> empty state: first apply, running the foundation stage"
      apply_stage foundation
    else
      echo "==> state has no platform resources; running the foundation stage"
      apply_stage foundation
    fi
    create_service_agents
    grant_kms_to_agents
    grant_gke_service_agent
    # Must run before the platform stage: a soft-deleted log bucket from a
    # previous teardown blocks it with a 400 that mentions only ACTIVE state.
    undelete_log_buckets
    grant_org_policy_admin
    apply_stage platform
    # Second pass: the Workload Identity bindings need the cluster's identity
    # pool, and for_each keys must be known at plan time, so they cannot be
    # created in the same apply that creates the cluster.
    echo
    echo "==> second pass: Workload Identity bindings (needs the cluster to exist)"
    tofu apply -input=false -auto-approve -var-file="$VARFILE" \
      -var "stage=platform" -var "bind_workload_identity=true"
    echo
    echo "note: stage=edge is deliberately NOT applied here. It needs the zonal"
    echo "      NEGs that only exist once agentgateway is installed. Run"
    echo "      ./scripts/85-edge.sh after 70-agentgateway.sh."
    ;;
  edge)
    apply_stage edge
    ;;
  destroy)
    tofu destroy -input=false -auto-approve -var-file="$VARFILE" -var "stage=${TOFU_STAGE:-edge}"
    exit 0
    ;;
  *) echo "usage: 10-tofu.sh [plan|apply|edge|destroy]" >&2; exit 1 ;;
esac

[[ "$ACTION" == "apply" ]] || exit 0

# ── emit .env.tofu ─────────────────────────────────────────────────────────────
# Resolve the Artifact Registry host from the API rather than composing it: the
# "<region>-docker" prefix is a public-GCP convention, unconfirmed for Berlin.
ENV_OUT="$LAB_ROOT/deploy/.env.tofu"
mkdir -p "$(dirname "$ENV_OUT")"

CLUSTER="$(tofu output -raw cluster_name 2>/dev/null || true)"
AR_REPO_NAME="$(tofu output -raw registry_repo 2>/dev/null || true)"
SQL_CONN="$(tofu output -raw sql_connection_name 2>/dev/null || true)"

REAL_AR_HOST=""
if [[ -n "$AR_REPO_NAME" ]]; then
  URI="$(gcloud artifacts repositories describe "$AR_REPO_NAME" \
    --project "$PROJECT_ID" --location "$UNIVERSE_REGION" \
    --format='value(registryUri)' 2>/dev/null || true)"
  REAL_AR_HOST="${URI%%/*}"
fi

{
  echo "# Generated by scripts/10-tofu.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Never commit."
  echo "TOFU_PROFILE=${PROFILE}"
  echo "CLUSTER_NAME=${CLUSTER}"
  echo "AR_REPO_NAME=${AR_REPO_NAME}"
  echo "AR_REGISTRY_URI=${URI:-}"
  echo "AR_HOST_RESOLVED=${REAL_AR_HOST}"
  echo "SQL_CONNECTION_NAME=${SQL_CONN}"
  echo "SQL_DATABASE=$(tofu output -raw sql_database 2>/dev/null || true)"
  echo "SQL_USERNAME=$(tofu output -raw sql_username 2>/dev/null || true)"
  echo "KMS_ENVELOPE_KEY=$(tofu output -raw envelope_encrypt_hint 2>/dev/null || true)"
  echo "WEIGHTS_BUCKET=$(tofu output -json buckets 2>/dev/null | jq -r '.weights // empty' 2>/dev/null || true)"
  echo "AUDIT_TOPIC=$(tofu output -raw audit_topic 2>/dev/null || true)"
  echo "AUDIT_BQ_DATASET=$(tofu output -raw audit_bq_dataset 2>/dev/null || true)"
  echo "PRIVATE_DNS_ZONE=$(tofu output -raw private_dns_zone 2>/dev/null || true)"
  echo "WORKLOAD_IDENTITY_POOL=$(tofu output -raw workload_identity_pool 2>/dev/null || true)"
  # Sensitive: the AgentRegistry DB password. This file is gitignored.
  echo "SQL_PASSWORD=$(tofu output -raw sql_password 2>/dev/null || true)"
} >"$ENV_OUT"
chmod 600 "$ENV_OUT"

echo
echo "wrote $ENV_OUT"
if [[ -n "$REAL_AR_HOST" && -n "${AR_HOST:-}" && "$REAL_AR_HOST" != "$AR_HOST" ]]; then
  echo "NOTE: real AR host is '$REAL_AR_HOST' but .env.local has AR_HOST='$AR_HOST' — update .env.local." >&2
fi
echo
echo "next: $(tofu output -raw get_credentials_command 2>/dev/null || echo '(no cluster in this profile)')"
echo "then: ./scripts/20-cluster-probes.sh"
