#!/usr/bin/env bash
# 62-istio-allowlists.sh — generate the WorkloadAllowlists that GKE Autopilot
# needs in order to admit istio-cni and ztunnel.
#
# We do not hand-write these. GKE generates them: annotate the pod template with
#   cloud.google.com/generate-allowlist: "true"
# and GKE Warden returns the exact WorkloadAllowlist for that workload appended
# to its rejection message. A server-side dry-run is enough, so this changes
# nothing in the cluster.
#
# The generated allowlist pins each container by image and matches its args, env
# names and securityContext exactly, so it MUST be regenerated for every Istio
# version bump and for any change to the Helm values used at install time. That
# is what this script is for.
#
# See docs/istio-ambient-gke-autopilot-guide.md for the full walkthrough,
# including every error this avoids.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"

# BSD sed needs an argument to -i, GNU sed must not have one. Decide once, rather
# than trying one and falling back on failure: on GNU a failed BSD-form call has
# already consumed '' as the script, and the fallback can write a file named ''.
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); else SED_INPLACE=(-i ''); fi

# CRITICAL: the allowlist matches the workload spec EXACTLY, including the
# container image and the set of env var names. `--set profile=ambient` changes
# ztunnel's image to :TAG-distroless and adds ISTIO_META_ENABLE_HBONE, so an
# allowlist generated without it is silently rejected. Render with precisely the
# values used to install. Keep this in step with 64-istio-ambient.sh.
ISTIO_PROFILE="${ISTIO_PROFILE:-ambient}"

# global.platform=gke ships the ResourceQuota that lets the system-node-critical
# priority class run in istio-system. In 1.30.4 that is all it does; in
# particular it does NOT fix the CNI directory below.
ISTIO_PLATFORM="${ISTIO_PLATFORM:-gke}"

# GKE's Container-Optimized OS mounts /opt/cni/bin read-only, so istio-cni cannot
# install its plugin there and crash-loops with "read-only file system" AFTER
# passing admission. The bin directory must be set explicitly to GKE's writable
# CNI path. This changes the rendered hostPath and therefore the allowlist.
ISTIO_CNI_BIN_DIR="${ISTIO_CNI_BIN_DIR:-/home/kubernetes/bin}"

# cni.useAppArmorAnnotation=false is the single most important value here.
# By default the chart requests AppArmor with the deprecated annotation
#   container.apparmor.security.beta.kubernetes.io/install-cni: unconfined
# and GKE's allowlist generator does NOT emit appArmorProfile for that form. The
# allowlist then never matches and admission fails citing the ORIGINAL capability
# and hostPath violations, with nothing anywhere pointing at AppArmor. Setting
# this false makes the chart use securityContext.appArmorProfile, which the
# generator does read. Requires Kubernetes 1.30+.
ISTIO_APPARMOR_ANNOTATION="${ISTIO_APPARMOR_ANNOTATION:-false}"

OUT="$LAB_ROOT/istio-ambient/allowlists"
mkdir -p "$OUT"

require helm kubectl
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null 2>&1 || true

for CHART in cni ztunnel; do
  step "Generating the allowlist for istio-$CHART $ISTIO_VERSION"
  NEW="$OUT/.istio-$CHART.new"

  # Both charts expose podAnnotations, so the generate-allowlist annotation goes
  # in with --set and no YAML editing is needed. --set-string matters: plain
  # --set renders true as a boolean and the annotation is then invalid.
  #
  # cni.* values are ignored by the ztunnel chart and vice versa, so passing the
  # union to both is harmless and keeps this loop simple.
  helm template "istio-$CHART" "istio/$CHART" --version "$ISTIO_VERSION" \
      -n istio-system \
      --set profile="$ISTIO_PROFILE" \
      --set global.platform="$ISTIO_PLATFORM" \
      --set cni.cniBinDir="$ISTIO_CNI_BIN_DIR" \
      --set cni.useAppArmorAnnotation="$ISTIO_APPARMOR_ANNOTATION" \
      --set-string cni.podAnnotations."cloud\.google\.com/generate-allowlist"=true \
      --set-string podAnnotations."cloud\.google\.com/generate-allowlist"=true \
      2>/dev/null \
    | kubectl apply --dry-run=server -f - 2>&1 \
    | sed -n '/^apiVersion: auto.gke.io/,$p' > "$NEW"

  if [[ ! -s "$NEW" ]]; then
    # An empty result means the dry-run was ADMITTED, so Warden emitted nothing.
    # That normally means an allowlist for this workload is already installed.
    # Do not overwrite the existing file: it is very likely the one making that
    # true. Writing to a staging file first is what makes this safe.
    warn "istio-$CHART: nothing emitted (already admissible). Keeping the existing file."
    [[ -s "$OUT/istio-$CHART.yaml" ]] || warn "  and no previous file exists for istio-$CHART"
    rm -f "$NEW"
    continue
  fi

  # GKE timestamps the allowlist name, so a regeneration would create a SECOND
  # allowlist rather than replacing the first. Give it a stable name.
  sed "${SED_INPLACE[@]}" "s|^\\( *\\)name: allowlist-[0-9a-zt.-]*\$|\\1name: istio-$CHART-$ISTIO_VERSION|" "$NEW"

  mv "$NEW" "$OUT/istio-$CHART.yaml"
  ok "wrote $OUT/istio-$CHART.yaml"
  log "exemptions: $(grep -A4 '^exemptions:' "$OUT/istio-$CHART.yaml" | grep '^\s*-' | tr -d ' -' | tr '\n' ' ')"
  grep -q 'appArmorProfile' "$OUT/istio-$CHART.yaml" \
    && log "appArmorProfile present (generator read it from securityContext)"
done

step "Summary"
for f in "$OUT"/istio-*.yaml; do
  [[ -f "$f" ]] || continue
  printf '  %-28s %s bytes, name=%s\n' "$(basename "$f")" "$(wc -c <"$f" | tr -d ' ')" \
    "$(grep -m1 -A2 '^metadata:' "$f" | grep 'name:' | awk '{print $2}')"
done
log "next: upload to the bucket, then ./scripts/64-istio-ambient.sh"
