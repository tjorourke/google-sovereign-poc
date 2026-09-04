#!/usr/bin/env bash
# 64-istio-ambient.sh — install Istio ambient on GKE Autopilot in GCD.
#
# Run 62-istio-allowlists.sh first, upload the allowlists, authorise them on the
# org policy and the cluster, and install the AllowlistSynchronizer. This script
# assumes those are done; it asserts them rather than doing them, because they
# involve an organisation policy change and a ~20 minute cluster update.
#
# Four GCD/Autopilot specifics are baked in here, each of which cost time to find:
#
#   1. profile=ambient changes ztunnel's image to :TAG-distroless and adds an env
#      var, and cni.useAppArmorAnnotation=false changes how AppArmor is expressed.
#      The WorkloadAllowlist pins the image and lists env names, so the allowlist
#      must be generated with the SAME helm values used here or admission
#      silently fails, citing capabilities and hostPath rather than the real
#      mismatch.
#
#   2. cni.cniBinDir must point at GKE's writable CNI directory. Container-
#      Optimized OS mounts /opt/cni/bin read-only, so the default makes istio-cni
#      crash-loop with "read-only file system" AFTER passing admission.
#      global.platform=gke does NOT fix this in 1.30.4; it only adds a
#      ResourceQuota.
#
#   3. Autopilot gates the system-node-critical priority class per namespace with
#      a ResourceQuota. Without one in istio-system the DaemonSets fail with
#      "insufficient quota to match these scopes", which looks nothing like a
#      priority class problem. global.platform=gke ships one; we also keep our
#      own copy so the dependency is explicit.
#
#   4. Pods admitted via an allowlist get autopilot.gke.io/no-connect, and
#      Autopilot then refuses exec and port-forward into them. `istioctl
#      ztunnel-config` therefore cannot be used here. Verify from logs and from
#      traffic behaviour instead: see 66-istio-health.sh.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
assert_universe
kube_context
assert_kube_reachable

ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"
ISTIO_PROFILE="${ISTIO_PROFILE:-ambient}"
ISTIO_PLATFORM="${ISTIO_PLATFORM:-gke}"
# Keep in step with 62-istio-allowlists.sh.
ISTIO_CNI_BIN_DIR="${ISTIO_CNI_BIN_DIR:-/home/kubernetes/bin}"
# See 62-istio-allowlists.sh for why this must be false, and must match.
ISTIO_APPARMOR_ANNOTATION="${ISTIO_APPARMOR_ANNOTATION:-false}"
AMBIENT_NAMESPACES="${AMBIENT_NAMESPACES:-kagent model}"
YAML_DIR="$LAB_ROOT/istio-ambient"
CTX="$(kubectl config current-context)"

require helm kubectl

step "Preflight: the allowlists must already be installed"
# Assert by NAME, not by count. A count admits any two WorkloadAllowlists --
# including ones another synchroniser installed -- and the cniBinDir assertion
# below needs these two specifically. 62-istio-allowlists.sh stamps these names
# on deliberately, replacing GKE's timestamped default.
# Keep as a string: bash 3.2 (the macOS default, and what env bash resolves to
# here) errors on ${#arr[@]} for an empty array under set -u.
MISSING=""
for want in "istio-cni-$ISTIO_VERSION" "istio-ztunnel-$ISTIO_VERSION"; do
  kubectl get workloadallowlist "$want" >/dev/null 2>&1 || MISSING="$MISSING $want"
done
if [[ -n "$MISSING" ]]; then
  kubectl get workloadallowlists >&2 2>/dev/null || true
  die "missing WorkloadAllowlist(s):$MISSING
    Run 62-istio-allowlists.sh, upload to the bucket, add the EXACT gs:// object
    paths (a directory prefix is accepted by the org policy and the cluster flag,
    then refused by the synchroniser) to the
    container.managed.autopilotPrivilegedAdmission org policy and to the
    cluster's --autopilot-privileged-admission, then apply
    istio-ambient/allowlistsynchronizer.yaml and allow up to 10 minutes.
    If they never appear, read the synchroniser's own status:
      kubectl get allowlistsynchronizer -o yaml | sed -n '/^status:/,\$p'
    See docs/istio-ambient-on-gcd-autopilot.md."
fi
ok "istio-cni-$ISTIO_VERSION and istio-ztunnel-$ISTIO_VERSION installed"

# Assert the allowlist expects the same CNI directory we are about to install
# with. A mismatch here is the single most confusing failure mode: admission
# rejects the pod and cites capabilities and hostPath, never the directory.
WANT="$(kubectl get workloadallowlist -o jsonpath='{range .items[*]}{.matchingCriteria.volumes[?(@.name=="cni-bin-dir")].hostPath.path}{"\n"}{end}' 2>/dev/null | grep -v '^$' | head -1)"
if [[ -n "$WANT" && "$WANT" != "$ISTIO_CNI_BIN_DIR" ]]; then
  die "allowlist expects cniBinDir=$WANT but this script installs $ISTIO_CNI_BIN_DIR.
    Regenerate with: ISTIO_CNI_BIN_DIR=$WANT ./scripts/62-istio-allowlists.sh"
fi
[[ -n "$WANT" ]] && ok "allowlist and install agree on cniBinDir=$WANT"

step "Autopilot ResourceQuota for the system-node-critical priority class"
kubectl apply -f "$YAML_DIR/critical-pods-quota.yaml" >/dev/null 2>&1 \
  && ok "gcp-critical-pods quota present in istio-system" \
  || warn "could not apply the critical-pods quota"

step "Istio $ISTIO_VERSION control plane"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null 2>&1 || true

helm --kube-context "$CTX" upgrade -i istio-base istio/base \
  --version "$ISTIO_VERSION" -n istio-system --create-namespace >/dev/null 2>&1 \
  && ok "istio-base" || die "istio-base failed"

helm --kube-context "$CTX" upgrade -i istiod istio/istiod \
  --version "$ISTIO_VERSION" -n istio-system \
  --set profile="$ISTIO_PROFILE" --wait --timeout 10m >/dev/null 2>&1 \
  && ok "istiod (profile=$ISTIO_PROFILE)" || die "istiod failed"

step "Privileged data plane: istio-cni and ztunnel"
helm --kube-context "$CTX" upgrade -i istio-cni istio/cni \
  --version "$ISTIO_VERSION" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" \
  --set cni.cniBinDir="$ISTIO_CNI_BIN_DIR" \
  --set cni.useAppArmorAnnotation="$ISTIO_APPARMOR_ANNOTATION" >/dev/null 2>&1 \
  && ok "istio-cni" || die "istio-cni failed"

helm --kube-context "$CTX" upgrade -i ztunnel istio/ztunnel \
  --version "$ISTIO_VERSION" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" >/dev/null 2>&1 \
  && ok "ztunnel" || die "ztunnel failed"

step "Waiting for both DaemonSets"
for _ in $(seq 1 30); do
  READY=1
  for d in istio-cni-node ztunnel; do
    R="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
    W="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
    [[ -n "$R" && "$R" == "$W" && "$R" -gt 0 ]] || READY=0
  done
  [[ "$READY" -eq 1 ]] && break
  sleep 20
done
for d in istio-cni-node ztunnel; do
  R="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  W="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  [[ "$R" == "$W" && "$R" -gt 0 ]] && ok "$d $R/$W ready" || {
    warn "$d is $R/$W — recent events:"
    kubectl -n istio-system describe ds "$d" 2>/dev/null | sed -n '/Events:/,$p' | tail -4 >&2
    die "$d did not become ready"
  }
done

step "Enrolling namespaces in ambient"
# No pod restarts required: istio-cni captures running pods in place and stamps
# ambient.istio.io/redirection=enabled on each one.
for ns in $AMBIENT_NAMESPACES; do
  kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1 \
    && ok "$ns enrolled" || warn "could not label $ns"
done

step "L7 waypoint for the agent namespace"
kubectl apply -f "$YAML_DIR/waypoint/02-waypoint.yaml" >/dev/null 2>&1
for _ in $(seq 1 20); do
  P="$(kubectl -n kagent get gateway agent-waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  [[ "$P" == "True" ]] && break
  sleep 10
done
[[ "$P" == "True" ]] && ok "waypoint agent-waypoint Programmed" \
                     || warn "waypoint not Programmed yet"

step "Done"
log "verify enforcement with:  ./scripts/66-istio-health.sh"
