#!/usr/bin/env bash
# 20-allowlists.sh — the WorkloadAllowlists that admit Agent Substrate on GKE
# Autopilot in GCD.
#
#   ./20-allowlists.sh atelet   BEFORE installing: generate, upload and install
#                               the allowlist for the atelet DaemonSet
#   ./20-allowlists.sh worker   AFTER `kagent install`: capture the allowlist GKE
#                               generated when it refused the gVisor worker
#                               Deployment, upload and install it
#   ./20-allowlists.sh sync     (re)install the synchroniser for every file
#   ./20-allowlists.sh status   what is installed
#
# Two Substrate workloads are refused by Autopilot without an allowlist
# (Warden's reasons, verbatim on 2026-10-21):
#   atelet   DaemonSet: autogke-no-write-mode-hostpath, for writable hostPaths
#            /var/lib/ate and the kubelet plugin and device-plugin directories,
#            and for /dev (only /var/log/ is allowed)
#   worker   one Deployment per WorkerPool, created at runtime by Substrate's
#            controller to run runsc: autogke-default-linux-capabilities for
#            NET_ADMIN and SYS_ADMIN, autogke-no-write-mode-hostpath for /var/lib/ate
# Warden accepts the rest unaided: root, atelet's hostPort, SYS_PTRACE and the
# other worker capabilities, Unconfined seccomp and AppArmor.
# Everything else in Substrate and kagent passes Autopilot unaided (checked by
# rendering every chart; see README).
#
# How allowlisting works here was established for Istio ambient on this
# cluster: docs/istio-ambient-on-gcd-autopilot.md. In short: GKE Warden emits a
# ready-made WorkloadAllowlist when a refused pod carries the annotation
# cloud.google.com/generate-allowlist=true; the file goes into a bucket; an
# AllowlistSynchronizer installs it; and each object path must be authorised
# EXACTLY in the org policy and in the cluster's privileged-admission paths
# (allowlists/orgpolicy-autopilot-privileged-admission.yaml and the tofu profile).
#
# Allowlists pin images, args, env names and security contexts, so regenerate
# them for every Substrate version bump or values change that reaches either pod.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gcloud kubectl helm python3
assert_session
assert_kube

DIR="$LAB_ROOT/allowlists"
WORK="$LAB_ROOT/deploy/allowlists"
mkdir -p "$DIR" "$WORK"
GS="gs://${ALLOWLIST_BUCKET}/${ALLOWLIST_PREFIX}"
ATELET_NAME="substrate-atelet-${SUBSTRATE_VERSION}"
WORKER_NAME="substrate-ateworker-gvisor-${SUBSTRATE_VERSION}"

# set_allowlist_name FILE NAME — rewrite metadata.name, which Warden derives
# from the workload. A stable, versioned name keeps upgrades legible.
set_allowlist_name() {
  python3 - "$1" "$2" <<'EOF'
import sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, in_meta, child = [], False, None
for line in lines:
    if line == "metadata:":
        in_meta = True; out.append(line); continue
    if in_meta:
        if line and not line.startswith(" "):
            in_meta = False
        else:
            indent = len(line) - len(line.lstrip(" "))
            if child is None and line.strip():
                child = indent
            if indent == child and line.lstrip().startswith("name:"):
                line = " " * indent + "name: " + name
                in_meta = False
    out.append(line)
open(path, "w").write("\n".join(out))
EOF
}

upload() {  # upload FILE
  gcloud storage cp "$DIR/$1" "$GS/$1" >/dev/null 2>&1 || die "upload failed: $GS/$1"
  ok "uploaded $GS/$1"
}

sync_allowlists() {
  local paths=() f
  for f in atelet.yaml ateworker-gvisor.yaml; do
    [[ -s "$DIR/$f" ]] && paths+=("${ALLOWLIST_PREFIX}/$f")
  done
  [[ ${#paths[@]} -gt 0 ]] || die "no allowlist files in $DIR yet"
  # The synchroniser re-reads its files only when its spec changes: a file
  # re-uploaded to an existing path sat unsynced for 7+ minutes (2026-10-21)
  # until the path list changed, then installed in 5 seconds. So when the list
  # is unchanged, flip its order; the set of paths is what matters to GKE.
  local current
  current="$(kubectl get allowlistsynchronizer substrate -o jsonpath='{.spec.allowlistPaths[*]}' 2>/dev/null || true)"
  if [[ "$current" == "${paths[*]}" && ${#paths[@]} -gt 1 ]]; then
    local reversed=() i
    for (( i=${#paths[@]}-1; i>=0; i-- )); do reversed+=("${paths[$i]}"); done
    paths=("${reversed[@]}")
  fi
  {
    printf 'apiVersion: auto.gke.io/v1\nkind: AllowlistSynchronizer\nmetadata:\n  name: substrate\n'
    printf 'spec:\n  projectNumber: %s\n  bucketName: %s\n  allowlistPaths:\n' "$PROJECT_NUMBER" "$ALLOWLIST_BUCKET"
    for f in "${paths[@]}"; do printf '    - %s\n' "$f"; done
  } > "$DIR/allowlistsynchronizer.yaml"
  kubectl apply -f "$DIR/allowlistsynchronizer.yaml" >/dev/null \
    || die "the AllowlistSynchronizer was refused (are the paths in the org policy AND on the cluster?)"
  ok "AllowlistSynchronizer substrate -> ${paths[*]}"
}

wait_allowlist() {  # wait_allowlist NAME
  wait_until 300 "WorkloadAllowlist $1 installed" kubectl get workloadallowlist "$1" \
    || { kubectl get allowlistsynchronizer substrate -o yaml | sed -n '/^status:/,$p' >&2; die "allowlist $1 never appeared"; }
}

# The atelet DaemonSet document from the rendered chart.
atelet_daemonset() {
  render_substrate > "$WORK/substrate-render.yaml" || die "helm template failed for the substrate chart"
  python3 - "$WORK/substrate-render.yaml" <<'EOF'
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
for d in docs:
    if "\nkind: DaemonSet\n" in "\n" + d + "\n" and "\n  name: atelet\n" in d:
        print(d.strip()); break
else:
    sys.exit("no atelet DaemonSet in the render")
EOF
}

cmd_atelet() {
  step "atelet DaemonSet ($SUBSTRATE_VERSION) rendered with yaml/substrate-values.yaml"
  kubectl create ns ate-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  atelet_daemonset > "$WORK/atelet-ds.yaml"
  kubectl patch --local -f "$WORK/atelet-ds.yaml" --type merge -o yaml \
    -p '{"spec":{"template":{"metadata":{"annotations":{"cloud.google.com/generate-allowlist":"true"}}}}}' \
    > "$WORK/atelet-ds-annotated.yaml" || die "could not annotate the rendered DaemonSet"

  step "asking GKE Warden for the allowlist (server-side dry run, changes nothing)"
  kubectl apply --dry-run=server -f "$WORK/atelet-ds-annotated.yaml" > "$WORK/atelet-raw.txt" 2>&1 || true
  if grep -Eq '(created|configured|unchanged) \(server dry run\)' "$WORK/atelet-raw.txt"; then
    ok "already admitted by an installed allowlist; keeping allowlists/atelet.yaml"
  else
    sed -n '/^apiVersion: auto.gke.io/,$p' "$WORK/atelet-raw.txt" > "$WORK/atelet-new.yaml"
    [[ -s "$WORK/atelet-new.yaml" ]] || { cat "$WORK/atelet-raw.txt" >&2; die "Warden refused the DaemonSet but returned no allowlist"; }
    set_allowlist_name "$WORK/atelet-new.yaml" "$ATELET_NAME"
    mv "$WORK/atelet-new.yaml" "$DIR/atelet.yaml"
    ok "generated allowlists/atelet.yaml"
    grep -A3 '^exemptions:' "$DIR/atelet.yaml" | sed 's/^/    /' || true
  fi
  upload atelet.yaml
  sync_allowlists
  wait_allowlist "$ATELET_NAME"

  step "the unannotated DaemonSet, exactly as it will be installed"
  wait_until 120 "atelet DaemonSet admitted (dry run)" atelet_admitted \
    || { kubectl apply --dry-run=server -f "$WORK/atelet-ds.yaml" 2>&1 | tail -5 >&2; die "atelet is still refused"; }
}

atelet_admitted() {
  kubectl apply --dry-run=server -f "$WORK/atelet-ds.yaml" 2>&1 | grep -Eq '(created|configured|unchanged) \(server dry run\)'
}

worker_available() {
  local n
  n="$(kubectl -n kagent get deploy kagent-default -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [[ "${n:-0}" -ge 1 ]]
}

# Warden's refusal of the worker Deployment reaches us only through the
# controller that attempted it, so read its logs. JSON or console format.
extract_worker_allowlist() {
  kubectl -n ate-system logs deploy/ate-controller --since=3h 2>/dev/null > "$WORK/ate-controller.log" || true
  python3 - "$WORK/ate-controller.log" <<'EOF'
import json, sys
text = open(sys.argv[1], errors="replace").read()
candidates = []
for line in text.splitlines():
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    for v in rec.values():
        if isinstance(v, str) and "apiVersion: auto.gke.io/v1" in v:
            candidates.append(v)
raw = False
if not candidates and "apiVersion: auto.gke.io/v1" in text:
    candidates.append(text)
    raw = True
if not candidates:
    sys.exit(1)
blob = candidates[-1]
blob = blob[blob.rindex("apiVersion: auto.gke.io/v1"):]
# In a structured log the error string ENDS with the allowlist (Warden appends
# it last), so take the rest verbatim: it contains quotes ("true") of its own.
# Console-format logs carry other lines after it; stop at the first blank one.
if raw:
    blob = blob.split("\n\n", 1)[0]
print(blob.rstrip("\n"))
EOF
}

cmd_worker() {
  step "gVisor worker Deployment (WorkerPool kagent/kagent-default)"
  kubectl -n kagent get workerpool kagent-default >/dev/null 2>&1 \
    || die "WorkerPool kagent/kagent-default not found; run 40-kagent.sh first"
  if kubectl -n kagent get deploy kagent-default >/dev/null 2>&1; then
    ok "worker Deployment already admitted"
  else
    rm -f "$WORK/worker-new.yaml"
    for _ in $(seq 1 36); do
      extract_worker_allowlist > "$WORK/worker-new.yaml" 2>/dev/null && break
      sleep 5
    done
    [[ -s "$WORK/worker-new.yaml" ]] \
      || die "no generated allowlist in the ate-controller logs after 3 minutes; is the WorkerPool template annotated?"
    ok "found Warden's generated allowlist in the ate-controller logs"
    set_allowlist_name "$WORK/worker-new.yaml" "$WORKER_NAME"
    mv "$WORK/worker-new.yaml" "$DIR/ateworker-gvisor.yaml"
    ok "generated allowlists/ateworker-gvisor.yaml"
    grep -A6 '^exemptions:' "$DIR/ateworker-gvisor.yaml" | sed 's/^/    /' || true
  fi
  upload ateworker-gvisor.yaml
  sync_allowlists
  wait_allowlist "$WORKER_NAME"

  # The controller retries with backoff; touching the pool reconciles it now.
  kubectl -n kagent annotate workerpool kagent-default \
    "lab.solo.io/allowlist-synced=$(date -u +%Y%m%dT%H%M%SZ)" --overwrite >/dev/null
  wait_until 300 "worker Deployment created" kubectl -n kagent get deploy kagent-default \
    || { kubectl -n ate-system logs deploy/ate-controller --since=5m 2>&1 | tail -5 >&2; die "worker Deployment still refused"; }
  wait_until 600 "worker pods available" worker_available \
    || kubectl -n kagent describe deploy kagent-default | tail -15 >&2
}

cmd_status() {
  kubectl get allowlistsynchronizer,workloadallowlist 2>&1 | sed 's/^/  /'
  gcloud storage ls "$GS/" 2>&1 | sed 's/^/  /'
}

case "${1:-}" in
  atelet) cmd_atelet ;;
  worker) cmd_worker ;;
  sync)   sync_allowlists ;;
  status) cmd_status ;;
  *) echo "usage: $0 atelet|worker|sync|status" >&2; exit 64 ;;
esac
