#!/usr/bin/env bash
# 66-istio-health.sh — prove Istio ambient actually enforces something in this
# environment, rather than just having its pods Running.
#
# Six checks, in order of what they prove:
#
#   1. The privileged DaemonSets are admitted and healthy. On GKE Autopilot this
#      is only possible via a WorkloadAllowlist, so it is the first thing to
#      assert and the thing that was previously impossible on GCD.
#   2. Workloads are captured. istio-cni stamps ambient.istio.io/redirection on
#      every pod it enrols; without it a pod is in an "ambient" namespace and
#      still completely unmeshed.
#   3. mTLS is real. ztunnel reports the peer's SPIFFE identity on the connection,
#      which is what makes identity-based policy meaningful.
#   4. L4 policy: ztunnel allows one ServiceAccount and denies another, on
#      identity, not IP.
#   5. L7 policy: the waypoint denies a specific HTTP method while leaving others
#      working. This is the part ztunnel alone cannot do.
#   6. Policy removal restores traffic, so we know the deny was the policy and not
#      something incidentally broken.
#
# Note on debugging: pods admitted through a WorkloadAllowlist carry
# autopilot.gke.io/no-connect, and Autopilot's autogke-no-pod-connect-limitation
# then refuses exec and port-forward into them. So `istioctl ztunnel-config` and
# `istioctl proxy-config` cannot be used against ztunnel here. Every check below
# works from logs and from traffic behaviour instead.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

NS="${AGENT_NS:-kagent}"
WP="${WAYPOINT:-agent-waypoint}"
SVC="health-server.${NS}.svc.cluster.local:8080"
YAML_DIR="$LAB_ROOT/istio-ambient/waypoint"

# Match 62/64 so the allowlist assertion below can name the objects.
ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"

PASS=0; FAIL=0
pass() { ok "$*"; PASS=$((PASS+1)); }
fail() { warn "FAIL: $*"; FAIL=$((FAIL+1)); }

client_pod() {
  kubectl -n "$NS" get pod -l "app=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# HTTP status from one client identity to the health server. Prints the code, or
# 000 when the connection itself was refused (an L4 deny looks like this).
curl_status() {
  local app="$1" method="${2:-GET}" path="${3:-/}"
  # curl writes 000 itself when the connection fails, so do not add a fallback
  # echo as well or the two concatenate into "000000".
  local out
  out="$(kubectl -n "$NS" exec "$(client_pod "$app")" -c client -- \
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X "$method" \
    "http://${SVC}${path}" 2>/dev/null)"
  echo "${out:-000}"
}

# The test fixtures. This script used to assume health-server / health-allowed /
# health-denied were already present, which was true on a long-lived cluster and
# false on a from-empty build -- nothing else in the phase order applies them.
# The symptom was every probe returning 000 and five checks failing for what
# looked like a broken mesh. Create them here and wait, so the check owns its
# own fixtures.
step "0. Test fixtures in $NS"
kubectl apply -f "$YAML_DIR/05-health-test-workloads.yaml" >/dev/null 2>&1 \
  || die "could not apply $YAML_DIR/05-health-test-workloads.yaml"
FIXTURES_OK=1
for d in health-server health-allowed health-denied; do
  kubectl -n "$NS" rollout status deploy/"$d" --timeout=180s >/dev/null 2>&1 \
    || { warn "deploy/$d did not become ready"; FIXTURES_OK=0; }
done
[[ "$FIXTURES_OK" -eq 1 ]] \
  && ok "health-server, health-allowed and health-denied ready" \
  || die "test fixtures are not ready; every traffic check below would report 000"

step "1. Privileged DaemonSets admitted and healthy"
# Autopilot's autoscaler adds and removes nodes constantly, and a node it is
# draining keeps its DaemonSet pod in the desired count while that pod is
# already unschedulable. Insisting on ready == desired therefore flaps: it
# reported "istio-cni-node is 3/4" on a healthy cluster whose fourth node was
# mid-deletion. Discount the nodes that are on their way out.
DRAINING="$(kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"\n"}{end}{end}' 2>/dev/null \
  | grep -cE '^(ToBeDeletedByClusterAutoscaler|node\.kubernetes\.io/unschedulable)$' || true)"
DRAINING="${DRAINING:-0}"
for d in istio-cni-node ztunnel; do
  READY="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  WANT="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  READY="${READY:-0}"; WANT="${WANT:-0}"
  # One node can carry both taints, so cap the discount at the actual shortfall.
  NEED=$(( WANT - DRAINING )); [[ "$NEED" -lt 1 ]] && NEED=1
  if [[ "$READY" -ge "$NEED" && "$READY" -gt 0 ]]; then
    if [[ "$READY" -eq "$WANT" ]]; then
      pass "$d is $READY/$WANT ready"
    else
      pass "$d is $READY/$WANT ready ($(( WANT - READY )) on node(s) the autoscaler is draining)"
    fi
  else
    fail "$d is $READY/$WANT ready"
  fi
done
# By name, not by count: two unrelated WorkloadAllowlists would satisfy a count
# while the DaemonSets above were admitted by something else entirely.
ALLOW_MISSING=""
for want in "istio-cni-$ISTIO_VERSION" "istio-ztunnel-$ISTIO_VERSION"; do
  kubectl get workloadallowlist "$want" >/dev/null 2>&1 || ALLOW_MISSING="$ALLOW_MISSING $want"
done
[[ -z "$ALLOW_MISSING" ]] \
  && pass "WorkloadAllowlists istio-cni-$ISTIO_VERSION and istio-ztunnel-$ISTIO_VERSION installed" \
  || fail "missing WorkloadAllowlist(s):$ALLOW_MISSING"

step "2. Workloads captured by ambient"
UNCAPTURED="$(kubectl -n "$NS" get pods -o json 2>/dev/null | python3 -c "
import json,sys
bad=[p['metadata']['name'] for p in json.load(sys.stdin)['items']
     if p['status'].get('phase')=='Running'
     and (p['metadata'].get('annotations') or {}).get('ambient.istio.io/redirection')!='enabled'
     and not p['metadata']['name'].startswith('${WP}')]
print(' '.join(bad))
")"
[[ -z "$UNCAPTURED" ]] && pass "every running pod in $NS is captured" \
                       || fail "not captured: $UNCAPTURED"

step "3. mTLS: ztunnel reports peer SPIFFE identities"
# Read this from ztunnel's Prometheus metrics rather than its log. The log line
# only appears for certain events and rotates, which made an earlier log-grep
# version of this check flaky. Metrics carry source_principal and
# destination_principal on every connection ztunnel has handled.
#
# We cannot exec into ztunnel (autopilot.gke.io/no-connect), but its metrics port
# is an ordinary network endpoint, so we scrape it FROM a client pod. Use the
# ztunnel on the same node as the client so its counters include our traffic.
CP="$(client_pod health-allowed)"
NODE="$(kubectl -n "$NS" get pod "$CP" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
ZIP="$(kubectl -n istio-system get pods -l app=ztunnel -o json 2>/dev/null | python3 -c "
import json,sys
node='$NODE'
for p in json.load(sys.stdin)['items']:
    if p['spec'].get('nodeName')==node:
        print(p['status'].get('podIP','')); break
")"
curl_status health-allowed >/dev/null 2>&1
if [[ -z "$ZIP" ]]; then
  fail "could not find a ztunnel pod IP on node $NODE"
else
  METRICS="$(kubectl -n "$NS" exec "$CP" -c client -- \
    curl -s -m 10 "http://${ZIP}:15020/metrics" 2>/dev/null)"
  SRC="$(echo "$METRICS" | grep -oE 'source_principal="spiffe://[^"]*"' | sort -u)"
  DST="$(echo "$METRICS" | grep -oE 'destination_principal="spiffe://[^"]*"' | sort -u)"
  if [[ -n "$SRC" && -n "$DST" ]]; then
    pass "ztunnel reports mTLS peer identities ($(echo "$SRC" | wc -l | tr -d ' ') source, $(echo "$DST" | wc -l | tr -d ' ') destination)"
    echo "$SRC" | head -2 | sed 's/^/      /' >&2
    echo "$DST" | head -4 | sed 's/^/      /' >&2
  else
    fail "no SPIFFE principals in ztunnel metrics on $NODE"
  fi
fi

step "4. L4 policy, enforced by ztunnel on identity"
BASE_A="$(curl_status health-allowed)"
BASE_D="$(curl_status health-denied)"
[[ "$BASE_A" == "200" && "$BASE_D" == "200" ]] \
  && pass "baseline: both identities reach the server (allowed=$BASE_A denied=$BASE_D)" \
  || fail "baseline broken before any policy (allowed=$BASE_A denied=$BASE_D)"

kubectl apply -f "$YAML_DIR/06-l4-test-policy.yaml" >/dev/null 2>&1
sleep 8
L4_A="$(curl_status health-allowed)"
L4_D="$(curl_status health-denied)"
if [[ "$L4_A" == "200" && "$L4_D" != "200" ]]; then
  pass "L4 ALLOW policy: health-allowed=$L4_A, health-denied=$L4_D (denied at L4)"
else
  fail "L4 policy did not discriminate (allowed=$L4_A denied=$L4_D)"
fi
kubectl delete -f "$YAML_DIR/06-l4-test-policy.yaml" >/dev/null 2>&1
sleep 8

step "5. L7 policy, enforced by the waypoint on HTTP method"
PROG="$(kubectl -n "$NS" get gateway "$WP" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
[[ "$PROG" == "True" ]] && pass "waypoint $WP is Programmed" || fail "waypoint $WP not Programmed"

kubectl -n "$NS" label service health-server istio.io/use-waypoint="$WP" --overwrite >/dev/null 2>&1
sleep 8
kubectl apply -f "$YAML_DIR/07-l7-test-policy.yaml" >/dev/null 2>&1
sleep 8
GETC="$(curl_status health-allowed GET)"
DELC="$(curl_status health-allowed DELETE)"
if [[ "$GETC" == "200" && "$DELC" == "403" ]]; then
  pass "L7 method policy: GET=$GETC, DELETE=$DELC (403 from the waypoint)"
else
  fail "L7 method policy did not discriminate (GET=$GETC DELETE=$DELC)"
fi

step "6. Removing the policy restores traffic"
kubectl delete -f "$YAML_DIR/07-l7-test-policy.yaml" >/dev/null 2>&1
sleep 8
DEL_AFTER="$(curl_status health-allowed DELETE)"
[[ "$DEL_AFTER" == "200" ]] && pass "DELETE=$DEL_AFTER once the policy is removed" \
                            || fail "DELETE=$DEL_AFTER after policy removal, expected 200"
kubectl -n "$NS" label service health-server istio.io/use-waypoint- >/dev/null 2>&1

step "Result"
log "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || die "$FAIL check(s) failed"
ok "Istio ambient L4 and L7 enforcement verified on GKE Autopilot in GCD"
