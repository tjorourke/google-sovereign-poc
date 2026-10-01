#!/usr/bin/env bash
# 26-labels-health.sh — Google's ask: every pod we run carries a company
# identifier. Lists any pod outside the GKE-managed namespaces that does not
# have $COMPANY_LABEL_KEY=$COMPANY_LABEL_VALUE, and exits non-zero if one exists.
#
# GKE's own namespaces are excluded: their pods are Google's, not ours, and
# Autopilot refuses writes there anyway.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl jq

EXCLUDE='^(kube-system|kube-public|kube-node-lease|gke-.*|gmp-.*|gke-managed-.*)$'

step "pods without $COMPANY_LABEL_KEY=$COMPANY_LABEL_VALUE"
missing="$(kc get pods -A -o json | jq -r --arg k "$COMPANY_LABEL_KEY" --arg v "$COMPANY_LABEL_VALUE" --arg ex "$EXCLUDE" '
  .items[]
  | select(.metadata.namespace | test($ex) | not)
  | select(.status.phase != "Succeeded")
  | select((.metadata.labels[$k] // "") != $v)
  | "\(.metadata.namespace)/\(.metadata.name)  owner=\(.metadata.ownerReferences[0].kind // "-")/\(.metadata.ownerReferences[0].name // "-")"')"
total="$(kc get pods -A -o json | jq --arg ex "$EXCLUDE" '[.items[] | select(.metadata.namespace | test($ex) | not)] | length')"

if [[ -z "$missing" ]]; then
  ok "all $total pods outside GKE-managed namespaces carry $COMPANY_LABEL_KEY=$COMPANY_LABEL_VALUE"
else
  echo "$missing" >&2
  die "$(wc -l <<<"$missing" | tr -d ' ') of $total pods are missing the label"
fi
