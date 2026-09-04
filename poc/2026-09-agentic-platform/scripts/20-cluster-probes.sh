#!/usr/bin/env bash
# 20-cluster-probes.sh — the Phase 0 probes that need a live cluster.
# Answers 0.2, 0.3, 0.5, 0.6, 0.9, 0.11, 0.12, 0.13 from PLAN.md and writes
# verbatim output to feedback/google/evidence/.
#
# Every one of these has a plan consequence. Read the summary at the end.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gcloud kubectl
load_env
assert_universe

NS="gcd-probe"
OUT="$REPO_ROOT/feedback/google/evidence/berlin-cluster-probes-$(date -u +%Y-%m-%d).txt"
mkdir -p "$(dirname "$OUT")"

RESULTS=()
record() { RESULTS+=("$1"); printf '%s\n' "$1" >>"$OUT"; }

{
  printf '# Berlin GCD in-cluster probes — %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# cluster=%s project=%s\n\n' "${CLUSTER_NAME:-?}" "$PROJECT_ID"
} >"$OUT"

cap() { printf '\n----- $ %s\n' "$*" >>"$OUT"; "$@" >>"$OUT" 2>&1; }

kc get ns "$NS" >/dev/null 2>&1 || kc create ns "$NS" >/dev/null
trap 'kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

# ── 0.5 StorageClass: Hyperdisk Balanced is the only disk type in GCD ─────────
step "0.5 StorageClasses"
cap kc get storageclass -o wide
SC="$(kc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
DEFAULT_SC="$(kc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)"
log "classes: ${SC:-none}"
record "0.5 storageclasses=[${SC:-none}] default=${DEFAULT_SC:-none}"

# ── 0.13 GatewayClasses: does GKE ship its own Gateway controller here ───────
step "0.13 GatewayClasses (GKE's own, before we install any Solo CRDs)"
cap kc get gatewayclass -o wide
GWC="$(kc get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
log "gatewayclasses: ${GWC:-none}"
if [[ "$GWC" == *"regional-external"* ]]; then
  record "0.13 GKE Gateway present: ${GWC} -> can front agentgateway with a GKE-managed ALB"
else
  record "0.13 GKE Gateway classes ABSENT (got: ${GWC:-none}) -> wire the regional ALB by hand in OpenTofu against a standalone NEG"
fi

# ── 0.9 hostAliases: the fallback ingress path depends on this ───────────────
step "0.9 hostAliases accepted by Autopilot admission"
if kc -n "$NS" apply -f - >>"$OUT" 2>&1 <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: probe-hostalias
spec:
  restartPolicy: Never
  hostAliases:
    - ip: "10.0.0.1"
      hostnames: ["keycloak.probe.invalid"]
  containers:
    - name: c
      image: gcr.io/google-containers/busybox:1.27.2
      command: ["sh","-c","grep keycloak /etc/hosts && sleep 2"]
      resources:
        requests: { cpu: "250m", memory: "512Mi" }
YAML
then
  record "0.9 hostAliases ACCEPTED by admission"
else
  record "0.9 hostAliases REJECTED -> localtest.me fallback is dead; private DNS zone becomes mandatory"
fi

# ── 0.3 image pull: can nodes reach ghcr.io / us-docker.pkg.dev directly ─────
step "0.3 direct image pull from an unmirrored public registry"
kc -n "$NS" apply -f - >>"$OUT" 2>&1 <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: probe-pull-ghcr
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: ghcr.io/agentgateway/agentgateway:v1.5.0
      command: ["sh","-c","echo pulled; sleep 2"]
      resources:
        requests: { cpu: "250m", memory: "512Mi" }
YAML

# ── 0.2 / 0.11 egress + public DNS from a pod ────────────────────────────────
step "0.2 / 0.11 pod egress and public DNS resolution"
# NOTE: unquoted heredoc on purpose — ${UNIVERSE_API_DOMAIN} must be expanded
# by the shell here, not left literal for busybox to fail on.
kc -n "$NS" apply -f - >>"$OUT" 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: probe-egress
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: gcr.io/google-containers/busybox:1.27.2
      command:
        - sh
        - -c
        - |
          echo "--- DNS (0.11)"
          nslookup ghcr.io          2>&1 | tail -5
          nslookup storage.googleapis.com 2>&1 | tail -5
          echo "--- egress (0.2)"
          wget -q -T 8 -O- https://ifconfig.me 2>&1 | head -2 || echo "EGRESS FAILED: ifconfig.me"
          wget -q -T 8 -S --spider https://ghcr.io/v2/ 2>&1 | head -5 || echo "EGRESS FAILED: ghcr.io"
          echo "--- in-universe API endpoint"
          wget -q -T 8 -S --spider "https://storage.${UNIVERSE_API_DOMAIN}/" 2>&1 | head -3 || echo "IN-UNIVERSE FAILED"
      resources:
        requests: { cpu: "250m", memory: "512Mi" }
YAML

# ── 0.12 Service type=LoadBalancer: does Tier 1 exist at all ─────────────────
step "0.12 Service type=LoadBalancer external IP"
kc -n "$NS" apply -f - >>"$OUT" 2>&1 <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: probe-lb
  annotations:
    cloud.google.com/neg: '{"exposed_ports": {"80":{}}}'
spec:
  type: LoadBalancer
  selector: { app: probe-nothing }
  ports:
    - port: 80
      targetPort: 8080
YAML

# ── 0.6 Autopilot admission for the awkward workloads ───────────────────────
step "0.6 Autopilot admission: a Postgres-shaped StatefulSet with a PVC"
kc -n "$NS" apply --dry-run=server -f - >>"$OUT" 2>&1 <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: probe-pg
spec:
  serviceName: probe-pg
  replicas: 1
  selector: { matchLabels: { app: probe-pg } }
  template:
    metadata: { labels: { app: probe-pg } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          env: [{ name: POSTGRES_PASSWORD, value: probe }]
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        ${DEFAULT_SC:+storageClassName: ${DEFAULT_SC}}
        resources: { requests: { storage: 10Gi } }
YAML
if [[ $? -eq 0 ]]; then record "0.6 StatefulSet+PVC admitted (server dry-run)"; else record "0.6 StatefulSet+PVC REJECTED -> Cloud SQL for Postgres, ephemeral ClickHouse"; fi

# ── settle, then collect ─────────────────────────────────────────────────────
step "waiting 90s for pods to pull and run, and for the LB to provision"
sleep 90

step "results"
cap kc -n "$NS" get pods -o wide
cap kc -n "$NS" get svc probe-lb -o yaml
cap kc -n "$NS" describe pod probe-pull-ghcr
cap kc -n "$NS" logs probe-egress
cap kc -n "$NS" logs probe-hostalias
cap kc -n "$NS" get events --sort-by=.lastTimestamp

# 0.3
PULL_PHASE="$(kc -n "$NS" get pod probe-pull-ghcr -o jsonpath='{.status.phase}' 2>/dev/null || true)"
PULL_REASON="$(kc -n "$NS" get pod probe-pull-ghcr -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
if [[ "$PULL_PHASE" == "Succeeded" || "$PULL_PHASE" == "Running" ]]; then
  record "0.3 direct pull from ghcr.io WORKS -> mirroring optional for the lab, still mandatory for a customer"
else
  record "0.3 direct pull from ghcr.io FAILED (phase=$PULL_PHASE reason=${PULL_REASON:-?}) -> mirror everything into Artifact Registry first"
fi

# 0.2 / 0.11
EGRESS_LOG="$(kc -n "$NS" logs probe-egress 2>/dev/null || true)"
if grep -q "EGRESS FAILED" <<<"$EGRESS_LOG"; then
  record "0.2 pod egress to the internet FAILED -> self-hosted model is the ONLY option; mirror everything"
elif [[ -n "$EGRESS_LOG" ]]; then
  record "0.2 pod egress to the internet WORKS via Cloud NAT"
else
  record "0.2 INCONCLUSIVE — probe-egress produced no logs"
fi
if grep -qi "can't resolve\|NXDOMAIN\|no answer" <<<"$EGRESS_LOG"; then
  record "0.11 public DNS from a pod is BLOCKED or partial"
else
  record "0.11 public DNS from a pod resolves"
fi

# 0.12
LB_IP="$(kc -n "$NS" get svc probe-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -n "$LB_IP" ]]; then
  record "0.12 Service type=LoadBalancer got external IP ${LB_IP} -> Tier 1 edge is viable"
else
  record "0.12 Service type=LoadBalancer got NO external IP after 90s -> Tier 1 may be blocked; check events, then fall back to internal ALB + port-forward"
fi
NEG_STATUS="$(kc -n "$NS" get svc probe-lb -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' 2>/dev/null || true)"
record "0.12b NEG annotation honoured: ${NEG_STATUS:-none} (this is how 85-edge.sh finds the NEGs)"

# ── summary ──────────────────────────────────────────────────────────────────
printf '\n\033[1;32m═══ probe summary ═══\033[0m\n' >&2
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r" >&2; done
printf '\n  verbatim output: %s\n\n' "$OUT" >&2
