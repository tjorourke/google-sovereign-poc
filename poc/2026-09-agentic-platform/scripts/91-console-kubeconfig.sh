#!/usr/bin/env bash
# 91-console-kubeconfig.sh — a kubeconfig for the demo console that never expires.
#
# The Berlin workforce-identity login lasts about an hour. deploy/.kubeconfig
# authenticates through gke-gcloud-auth-plugin, so when that login lapses every
# kubectl the console runs fails, mid-demo. This gives the console its own
# identity instead: a ServiceAccount with a token held in a Secret, which does
# not expire, written into deploy/console.kubeconfig. The console prefers that
# file when it exists (google_sov.py), and needs no gcloud session at all.
#
# The account is bound to cluster-admin: the console deploys agents, reads every
# lab namespace and port-forwards, and a missing verb would break the demo in
# front of the audience. The file is mode 600 and gitignored (*.kubeconfig).
#
#   ./scripts/91-console-kubeconfig.sh            create (or refresh) and write
#   ./scripts/91-console-kubeconfig.sh --revoke   delete the token and the binding
#
# Needs a live gcloud login once, to create the account. Revoking deletes the
# Secret, which invalidates the token immediately.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl
load_env

NS=demo-console
SA=demo-console
SECRET=demo-console-token
OUT="${CONSOLE_KUBECONFIG:-$LAB_ROOT/deploy/console.kubeconfig}"

if [[ "${1:-}" == "--revoke" ]]; then
  kc delete clusterrolebinding "$SA" --ignore-not-found
  kc -n "$NS" delete secret "$SECRET" --ignore-not-found
  rm -f "$OUT"
  echo "revoked: $SECRET deleted, $OUT removed"
  exit 0
fi

kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f -
kc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA
  namespace: $NS
---
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET
  namespace: $NS
  annotations:
    kubernetes.io/service-account.name: $SA
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $SA
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: $SA
  namespace: $NS
EOF

# The token controller fills the Secret in asynchronously.
for _ in $(seq 1 30); do
  [[ -n "$(kc -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null)" ]] && break
  sleep 1
done

ctx="$(kube_context)"
server="$(kc config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
ca="$(kc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$server" && -n "$ca" ]] || die "could not read the API server and CA for context $ctx"

umask 077
token="$(kc -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)"
[[ -n "$token" ]] || die "the token controller never filled $NS/$SECRET"
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: berlin
  cluster:
    server: $server
    certificate-authority-data: $ca
users:
- name: $SA
  user:
    token: $token
contexts:
- name: berlin-console
  context:
    cluster: berlin
    user: $SA
current-context: berlin-console
EOF
unset token

KUBECONFIG="$OUT" kubectl get ns "$NS" >/dev/null || die "$OUT does not authenticate"
echo "wrote $OUT (ServiceAccount $NS/$SA, no gcloud needed). Restart the console to pick it up."
