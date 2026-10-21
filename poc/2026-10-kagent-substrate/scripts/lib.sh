#!/usr/bin/env bash
# lib.sh — shared by every script in this lab. Source it; do not run it.
#
# Kept separate from poc/2026-09-agentic-platform/scripts/lib.sh on purpose:
# that one carries Istio, AgentRegistry and Keycloak assumptions this cluster
# no longer has. What is shared is the universe (.env.local) and the isolated
# kubeconfig convention.
set -o pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$LAB_ROOT/../.." && pwd)"

[[ -f "$REPO_ROOT/.env.local" ]] || { echo "error: $REPO_ROOT/.env.local not found" >&2; exit 1; }
# shellcheck disable=SC1091
source "$REPO_ROOT/.env.local"
# shellcheck disable=SC1091
source "$LAB_ROOT/versions.env"

CLUSTER_NAME="${CLUSTER_NAME:-agentic}"

# An isolated kubeconfig, so nothing here can act on another cluster in
# ~/.kube/config, and nothing else can pick up this one by accident.
export KUBECONFIG="${GCD_KUBECONFIG:-$LAB_ROOT/deploy/.kubeconfig}"
mkdir -p "$(dirname "$KUBECONFIG")" "$LAB_ROOT/evidence"

# Client libraries (tofu's GCS backend, and anything else built on them) default
# to googleapis.com unless told otherwise.
export GOOGLE_CLOUD_UNIVERSE_DOMAIN="$UNIVERSE_API_DOMAIN"

step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*" >&2; }
log()  { printf '  %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

# The Berlin workforce login lasts about an hour, and an expired one surfaces as
# whatever command happened to run next. Check before anything that needs it.
assert_session() {
  gcloud auth print-access-token >/dev/null 2>&1 \
    || die "GCD session expired. Sign in again: $REPO_ROOT/scripts/gcd-auth.sh"
  [[ "$(gcloud config get-value universe_domain 2>/dev/null)" == "$UNIVERSE_API_DOMAIN" ]] \
    || die "gcloud universe_domain is not $UNIVERSE_API_DOMAIN; run $REPO_ROOT/scripts/gcd-auth.sh"
}

assert_kube() {
  kubectl get --raw /readyz --request-timeout=20s >/dev/null 2>&1 \
    || die "cluster unreachable with $KUBECONFIG. Run scripts/10-cluster.sh (and check the GCD session)."
}

# Licence keys and provider credentials, never committed and never echoed.
load_secrets() {
  local f="${SOLO_SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
  [[ -f "$f" ]] || die "secrets file not found: $f (set SOLO_SECRETS_FILE)"
  # shellcheck disable=SC1090
  { set +x; source "$f"; } >/dev/null 2>&1
}

# wait_until TIMEOUT_SECONDS DESCRIPTION CMD... — poll every 5s.
wait_until() {
  local timeout="$1" what="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= timeout )) && { warn "timed out after ${timeout}s waiting for: $what"; return 1; }
    sleep 5
  done
  ok "$what"
}

# The kagent CLI for KAGENT_VERSION, downloaded once and checksum-verified. It
# installs Substrate, its Pod Certificate controller and the development
# PostgreSQL before kagent itself, and is what the kagent docs prescribe.
kagent_cli() {
  local os arch dir bin
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/kagent/$KAGENT_VERSION"
  bin="$dir/kagent"
  if [[ ! -x "$bin" ]]; then
    mkdir -p "$dir"
    local asset="kagent-${os}-${arch}"
    local base="https://github.com/kagent-dev/kagent/releases/download/v${KAGENT_VERSION}"
    curl -fsSL -o "$dir/$asset" "$base/$asset" || die "could not download $asset"
    curl -fsSL -o "$dir/$asset.sha256" "$base/$asset.sha256" || die "could not download $asset.sha256"
    local want have
    want="$(awk '{print $1}' "$dir/$asset.sha256")"
    have="$(shasum -a 256 "$dir/$asset" | awk '{print $1}')"
    [[ -n "$want" && "$want" == "$have" ]] || { rm -f "$dir/$asset"; die "checksum mismatch for $asset"; }
    mv "$dir/$asset" "$bin" && chmod +x "$bin"
  fi
  printf '%s\n' "$bin"
}

# `kubectl ate`, Substrate's own CLI, for SUBSTRATE_VERSION. Substrate ships no
# binary release, so it is built once from the matching tag: from the local
# checkout at SUBSTRATE_SRC by `git archive` (which leaves that checkout's
# branch alone), else from a shallow clone of the public repo. Needs Go.
ate_cli() {
  local dir bin src="${SUBSTRATE_SRC:-$HOME/code/solo/substrate}" tag="v$SUBSTRATE_VERSION"
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/kagent-substrate-lab/substrate-$SUBSTRATE_VERSION"
  bin="$dir/kubectl-ate"
  if [[ ! -x "$bin" ]]; then
    command -v go >/dev/null 2>&1 || die "Go is needed to build kubectl-ate"
    rm -rf "$dir/src" && mkdir -p "$dir/src"
    if git -C "$src" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
      git -C "$src" archive "$tag" | tar -x -C "$dir/src" || die "git archive $tag from $src failed"
    else
      git clone -q --depth 1 --branch "$tag" https://github.com/kagent-dev/substrate.git "$dir/src" \
        || die "could not fetch Substrate $tag"
    fi
    (cd "$dir/src" && go build -mod=vendor -o "$bin" ./cmd/kubectl-ate) >&2 || die "kubectl-ate build failed"
    rm -rf "$dir/src"
  fi
  printf '%s\n' "$bin"
}

# A short-lived token for the ate-operator principal (yaml/ate-operator.yaml),
# which yaml/substrate-values.yaml makes a Substrate bootstrap owner.
ate_operator_token() {  # ate_operator_token FILE
  kubectl -n ate-system create token ate-operator --audience api.ate-system.svc --duration 30m > "$1" \
    || die "could not mint an ate-operator token (is yaml/ate-operator.yaml applied?)"
}

# Values files shared by the install (40-kagent.sh) and allowlist generation
# (20-allowlists.sh). Generation must render exactly what installation applies:
# a WorkloadAllowlist pins image, args, env names, security context and volumes.
SUBSTRATE_VALUES="$LAB_ROOT/yaml/substrate-values.yaml"
KAGENT_VALUES="$LAB_ROOT/yaml/kagent-values.yaml"
SUBSTRATE_CHART="oci://ghcr.io/kagent-dev/substrate/helm/substrate"

render_substrate() {
  # The same flags `kagent install` passes for a bundled-PostgreSQL install.
  helm template substrate "$SUBSTRATE_CHART" --version "$SUBSTRATE_VERSION" \
    -n ate-system \
    --set postgres.clientCertificates.enabled=true \
    -f "$SUBSTRATE_VALUES"
}
