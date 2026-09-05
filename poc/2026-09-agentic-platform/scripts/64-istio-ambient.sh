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

# Every pod-spec input comes from lib.sh, shared with 62-istio-allowlists.sh.
# They MUST match: the allowlist pins the image and matches the spec exactly.
istio_flavour
solo_registry_login
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
for want in "istio-cni-$ISTIO_CHART_VERSION" "istio-ztunnel-$ISTIO_CHART_VERSION"; do
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
ok "istio-cni-$ISTIO_CHART_VERSION and istio-ztunnel-$ISTIO_CHART_VERSION installed"

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

step "Istio control plane — $ISTIO_EDITION $ISTIO_CHART_VERSION"
log "chart=$ISTIO_CHART_REPO  hub=$ISTIO_HUB  tag=$ISTIO_TAG"

helm --kube-context "$CTX" upgrade -i istio-base "$(istio_chart base)" \
  --version "$ISTIO_CHART_VERSION" -n istio-system --create-namespace \
  --set defaultRevision=default >/dev/null 2>&1 \
  && ok "istio-base" || die "istio-base failed"

# The Solo Enterprise licence goes on ISTIOD, as license.value. Without it the
# build runs but the enterprise gates stay shut -- notably AuthorizationPolicy
# attachment, which is exactly what 66-istio-health.sh asserts. Upstream ignores
# the value, so passing it unconditionally is safe.
ISTIO_LICENSE="${SOLO_ISTIO_LICENSE_KEY:-${ISTIO_LICENSE_KEY:-}}"
if [[ "$ISTIO_EDITION" == "enterprise" && -z "$ISTIO_LICENSE" ]]; then
  die "SOLO_ISTIO_LICENSE_KEY not set.
    source ~/code/solo/secrets/secrets-envs.sh, or run with ISTIO_EDITION=oss"
fi

helm --kube-context "$CTX" upgrade -i istiod "$(istio_chart istiod)" \
  --version "$ISTIO_CHART_VERSION" -n istio-system --wait --timeout 10m \
  -f - >/dev/null 2>&1 <<EOF \
  && ok "istiod (profile=$ISTIO_PROFILE, $ISTIO_EDITION)" || die "istiod failed"
profile: ${ISTIO_PROFILE}
global:
  hub: ${ISTIO_HUB}
  tag: ${ISTIO_TAG}
  platform: ${ISTIO_PLATFORM}
istio_cni:
  enabled: true
license:
  value: ${ISTIO_LICENSE}
EOF

step "Privileged data plane: istio-cni and ztunnel"
# These two are the workloads the WorkloadAllowlists admit. Values here must be
# identical to what 62-istio-allowlists.sh rendered.
helm --kube-context "$CTX" upgrade -i istio-cni "$(istio_chart cni)" \
  --version "$ISTIO_CHART_VERSION" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" \
  --set global.hub="$ISTIO_HUB" \
  --set global.tag="$ISTIO_TAG" \
  --set cni.cniBinDir="$ISTIO_CNI_BIN_DIR" \
  --set cni.useAppArmorAnnotation="$ISTIO_APPARMOR_ANNOTATION" >/dev/null 2>&1 \
  && ok "istio-cni" || die "istio-cni failed"

# ztunnel takes hub/tag at the TOP LEVEL, not under global. Setting only
# global.hub here silently leaves ztunnel on the chart default image, which
# then does not match the allowlist that was generated for the Solo image.
helm --kube-context "$CTX" upgrade -i ztunnel "$(istio_chart ztunnel)" \
  --version "$ISTIO_CHART_VERSION" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" \
  --set hub="$ISTIO_HUB" \
  --set tag="$ISTIO_TAG" >/dev/null 2>&1 \
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
# CREATE then label. On a from-empty build these namespaces do not exist yet --
# kagent is created by phase 40 and model by phase 60, both of which run AFTER
# this phase -- so `kubectl label ns` failed, the error went to /dev/null, and
# the waypoint below was applied into a namespace that was not there. Phase 66
# then tested enforcement against nothing and every probe returned 000.
# Creating the namespace here is harmless: the later `helm install` adopts it.
#
# No pod restarts required: istio-cni captures running pods in place and stamps
# ambient.istio.io/redirection=enabled on each one.
for ns in $AMBIENT_NAMESPACES; do
  kubectl create namespace "$ns" >/dev/null 2>&1 || true
  if kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1; then
    ok "$ns created and enrolled"
  else
    die "could not enrol $ns in ambient; everything downstream depends on it"
  fi
done

step "L7 waypoint for the agent namespace"
# Do not swallow this. A failed apply here used to surface only as
# "waypoint not Programmed yet", which reads like slow reconciliation rather
# than the resource never having been created.
if ! kubectl apply -f "$YAML_DIR/waypoint/02-waypoint.yaml" 2>/tmp/waypoint-apply.err >/dev/null; then
  sed 's/^/    /' /tmp/waypoint-apply.err >&2
  die "could not apply the waypoint"
fi
P=""
for _ in $(seq 1 30); do
  P="$(kubectl -n kagent get gateway agent-waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  [[ "$P" == "True" ]] && break
  sleep 10
done
# A waypoint that never programs means no L7 path at all, so fail the phase
# rather than leaving phase 66 to report it as eight mysterious failures.
[[ "$P" == "True" ]] && ok "waypoint agent-waypoint Programmed" \
                     || die "waypoint agent-waypoint did not become Programmed.
    kubectl -n kagent describe gateway agent-waypoint"

step "Done"
log "verify enforcement with:  ./scripts/66-istio-health.sh"
