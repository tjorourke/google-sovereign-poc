# Running Istio ambient on GKE Autopilot

A complete, tested walkthrough for deploying Istio ambient mesh to a GKE
Autopilot cluster, including every error you will hit and what it actually
means.

Everything here uses `helm`, `kubectl` and `gcloud`. No scripts, no editing
generated YAML by hand.

Verified on GKE Autopilot `v1.35.6-gke.1049000`, Istio 1.30.4, 2026-09-04.

---

## Why this used to be impossible

Autopilot refuses privileged workloads. Istio ambient needs two of them:

| Component | What it needs |
|---|---|
| `istio-cni` | `NET_ADMIN`, `NET_RAW`, `SYS_PTRACE`, `SYS_ADMIN`, `DAC_OVERRIDE`; write-mode hostPath on the CNI directories; read hostPath on `/proc` |
| `ztunnel` | `NET_ADMIN`, `SYS_ADMIN`, `NET_RAW`; write-mode hostPath for its socket directory |

Neither runs as `privileged: true`, which surprises people. The blockers are
Linux capabilities and hostPath, not privileged mode.

For years the answer was "use a Standard cluster". It no longer is. Autopilot
now supports **privileged workload admission control**: you install a
`WorkloadAllowlist` describing exactly one workload, and Autopilot admits that
workload and nothing else.

Two things to be clear about before you start:

- This is **self-managed Istio**. It is not Cloud Service Mesh.
- Running your **own** allowlists is documented as available "only to eligible
  Google Cloud customers", with access requested through Cloud Customer Care.
  Our organisation needed no request and the policy was accepted first time, but
  check yours before promising a timeline.
  ([docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/autopilot-privileged-allowlists))

---

## What Warden is, and the sequence that has to happen

**Warden** is GKE's admission control layer, and it is what makes Autopilot
Autopilot. It is a pair of Google-managed webhooks registered in every Autopilot
cluster:

```
$ kubectl get validatingwebhookconfigurations | grep warden
warden-validating.config.common-webhooks.networking.gke.io   1   27h

$ kubectl get mutatingwebhookconfigurations | grep warden
warden-mutating.config.common-webhooks.networking.gke.io     1   27h
```

Three properties matter:

- It runs in the **control plane**, at `https://localhost:5443/webhook/warden-validating`
  from the API server's point of view. Not a pod in your cluster. You cannot
  patch, disable or delete it.
- `failurePolicy: Fail`. If Warden is unreachable, admission is refused. It
  fails closed.
- Its rules cover more than pods. It also validates `pods/*` on `CONNECT`, which
  is what later blocks `kubectl exec` into allowlisted pods.

Every refusal names a constraint: `autogke-default-linux-capabilities`,
`autogke-no-write-mode-hostpath`, and so on. A `WorkloadAllowlist` waives named
constraints for one exactly-described workload.

### The sequence

```
                     ┌──────────────────────────────────────────┐
  YOU                │  1. helm template + generate-allowlist   │
                     │     annotation, kubectl --dry-run=server │
                     └────────────────────┬─────────────────────┘
                                          │ pod spec
                                          ▼
                     ┌──────────────────────────────────────────┐
  CONTROL PLANE      │  2. warden-mutating   (defaults CPU etc) │
                     │  3. warden-validating (REFUSES it)       │
                     │     ...and prints a WorkloadAllowlist    │
                     │        that would have allowed it        │
                     └────────────────────┬─────────────────────┘
                                          │ YAML on stderr
                                          ▼
                     ┌──────────────────────────────────────────┐
  YOU                │  4. save it, upload to a GCS bucket      │
                     └────────────────────┬─────────────────────┘
                                          ▼
                     ┌──────────────────────────────────────────┐
  ORG / CLUSTER      │  5. org policy: allow that gs:// path    │
                     │     container.managed.                   │
                     │       autopilotPrivilegedAdmission       │
                     │  6. cluster: --autopilot-privileged-     │
                     │       admission=<same paths>             │
                     └────────────────────┬─────────────────────┘
                                          ▼
                     ┌──────────────────────────────────────────┐
  IN CLUSTER         │  7. AllowlistSynchronizer reads the      │
                     │     bucket as the GKE service agent and  │
                     │     creates WorkloadAllowlist objects    │
                     └────────────────────┬─────────────────────┘
                                          ▼
                     ┌──────────────────────────────────────────┐
  YOU                │  8. helm install for real (no annotation)│
                     │     warden-validating now finds a match  │
                     │     and ADMITS the pods                  │
                     └──────────────────────────────────────────┘
```

Step 5 gates step 6: the cluster flag's value must be drawn from the org
policy's `allowPaths`. And you cannot skip step 7 by applying a
`WorkloadAllowlist` with `kubectl` — GKE only accepts them from an authorised
bucket, via the synchroniser.

### The CRDs involved

All installed with the cluster, in `auto.gke.io/v1`:

```
$ kubectl api-resources | grep -iE 'allowlist'
allowlistedv2workloads    auto.gke.io/v1   false   AllowlistedV2Workload
allowlistedworkloads      auto.gke.io/v1   false   AllowlistedWorkload
allowlistsynchronizers    auto.gke.io/v1   false   AllowlistSynchronizer
workloadallowlists        auto.gke.io/v1   false   WorkloadAllowlist
gcpresourceallowlists     node.gke.io/v1   false   GCPResourceAllowlist
```

You interact with two of them:

- **`WorkloadAllowlist`** — the enforcement object. `exemptions` lists the Warden
  constraints waived; `matchingCriteria` describes the workload. Cluster-scoped.
- **`AllowlistSynchronizer`** — points at a bucket and object paths. Cluster-scoped.

`matchingCriteria` can express: `hostNetwork`, `hostPID`, `hostIPC`,
`hostUsers`, `volumes`, pod `securityContext.appArmorProfile`, and per-container
`image`, `command`, `args`, `env` (names only), `envFrom`, `volumeMounts`, and
`securityContext.{capabilities, privileged, appArmorProfile}`.

It deliberately **cannot** express `runAsUser`, `runAsGroup`, `runAsNonRoot` or
`hostPath.type`. Those are ignored during matching, so their absence from a
generated allowlist is correct, not a bug.

---

## Prerequisites

- GKE Autopilot cluster on **1.35 or later**
- `helm`, `kubectl`, `gcloud`
- Permission to set organization policy, and to update the cluster
- A Cloud Storage bucket in the same project

```bash
export CLUSTER=my-autopilot
export REGION=europe-west4
export PROJECT=my-project
export ORG_ID=123456789012
export PROJECT_NUMBER=210987654321
export BUCKET=my-allowlists
export ISTIO_VER=1.30.4

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update istio
```

---

## Step 0: see the failure for yourself

Worth doing once, because the error text is the map. Try to install ambient the
normal way:

```bash
helm install istio-cni istio/cni --version $ISTIO_VER \
  -n istio-system --create-namespace --set profile=ambient
```

Helm reports success. The DaemonSet does not:

```bash
$ kubectl -n istio-system get ds
NAME             DESIRED   CURRENT   READY
istio-cni-node   3         0         0

$ kubectl -n istio-system describe ds istio-cni-node | tail -6
Warning  FailedCreate  daemonset-controller  Error creating: admission webhook
"warden-validating.common-webhooks.networking.gke.io" denied the request:
GKE Warden rejected the request because it violates one or more constraints.
Violations details: {"[denied by autogke-default-linux-capabilities]":
["linux capability 'NET_ADMIN,SYS_ADMIN' on container 'install-cni' not allowed;
Autopilot only allows the capabilities: 'AUDIT_WRITE,CHOWN,DAC_OVERRIDE,FOWNER,
FSETID,KILL,MKNOD,NET_BIND_SERVICE,NET_RAW,SETFCAP,SETGID,SETPCAP,SETUID,
SYS_CHROOT,SYS_PTRACE'."],"[denied by autogke-no-write-mode-hostpath]":
["hostPath volume cni-bin-dir in container install-cni is accessed in write mode;
disallowed in Autopilot.", ... "hostPath volume cni-host-procfs used in container
install-cni uses path /proc which is not allowed in Autopilot. Allowed path
prefixes for hostPath volumes are: [/var/log/]."]}
Requested by user: 'system:serviceaccount:kube-system:daemon-set-controller'
To generate an allowlist for this workload, add the
'cloud.google.com/generate-allowlist: "true"' annotation to your Pod.
```

**Read the last two lines.** That is the whole mechanism. Note also the
requester: `daemonset-controller`, not you. The DaemonSet was created fine; its
pods are what Warden refuses, which is why `helm install` succeeds and nothing
runs.

Clean up before continuing:

```bash
helm uninstall istio-cni -n istio-system
```

---

## Step 1: create the bucket and grant the GKE service agent

The synchroniser reads the bucket **as the GKE service agent**, not as you.
Miss this grant and you get a synchroniser error that reads like a policy
problem.

```bash
gcloud storage buckets create "gs://${BUCKET}" \
  --location="${REGION}" \
  --uniform-bucket-level-access

# you, to upload
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/storage.objectUser"

# the GKE service agent, to read
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
  --role="roles/storage.admin"
```

---

## Step 2: generate the allowlists

You do not write these. GKE writes them.

Add `cloud.google.com/generate-allowlist: "true"` to the pod template and apply
with `--dry-run=server`. Both Istio charts expose `podAnnotations`, so this needs
no file editing:

```bash
mkdir -p allowlists && cd allowlists

helm template istio-cni istio/cni --version $ISTIO_VER -n istio-system \
  --set profile=ambient \
  --set global.platform=gke \
  --set cni.cniBinDir=/home/kubernetes/bin \
  --set cni.useAppArmorAnnotation=false \
  --set-string cni.podAnnotations."cloud\.google\.com/generate-allowlist"=true \
  | kubectl apply --dry-run=server -f - 2>&1 \
  | sed -n '/^apiVersion: auto.gke.io/,$p' > istio-cni-allowlist.yaml

helm template ztunnel istio/ztunnel --version $ISTIO_VER -n istio-system \
  --set profile=ambient \
  --set global.platform=gke \
  --set-string podAnnotations."cloud\.google\.com/generate-allowlist"=true \
  | kubectl apply --dry-run=server -f - 2>&1 \
  | sed -n '/^apiVersion: auto.gke.io/,$p' > ztunnel-allowlist.yaml
```

Four of those flags are load-bearing. Do not drop any of them; each is explained
in [Four flags that are not optional](#four-flags-that-are-not-optional) below.

`--dry-run=server` is essential. `--dry-run=client` never reaches the webhook and
produces nothing.

### What Warden prints

The allowlist arrives appended to the rejection, after a `---`:

```
Error from server (GKE Warden constraints violations): ... denied the request ...
Violations details: {"[denied by autogke-default-linux-capabilities]": ...}
Requested by user: '...'

This workload can be enabled using the following Custom Resource. To be used
in-cluster, the WorkloadAllowlist must be uploaded to Google Cloud Storage and
then installed using an AllowlistSynchronizer.
---
apiVersion: auto.gke.io/v1
kind: WorkloadAllowlist
metadata:
    name: allowlist-2026-09-04t17-44-08
    annotations:
        autopilot.gke.io/no-connect: "true"
exemptions:
    - autogke-default-linux-capabilities
    - autogke-no-write-mode-hostpath
matchingCriteria:
    containers:
        - name: install-cni
          image: registry.istio.io/release/install-cni:1.30.4-distroless
          command: [install-cni]
          args: [--log_output_level=info]
          securityContext:
            appArmorProfile:
                type: Unconfined
            capabilities:
                add: [NET_ADMIN, NET_RAW, SYS_PTRACE, SYS_ADMIN, DAC_OVERRIDE]
                drop: [ALL]
            privileged: false
          volumeMounts: [...]
    volumes:
        - hostPath: {path: /home/kubernetes/bin}
          name: cni-bin-dir
        ...
```

The `exemptions` are exactly the constraints it just denied.

**Give them stable names.** GKE timestamps the name, so a regeneration would
create a second allowlist instead of replacing the first:

```bash
sed -i 's|^\( *\)name: allowlist-[0-9a-zt.-]*$|\1name: istio-cni-'"$ISTIO_VER"'|' \
  istio-cni-allowlist.yaml
sed -i 's|^\( *\)name: allowlist-[0-9a-zt.-]*$|\1name: istio-ztunnel-'"$ISTIO_VER"'|' \
  ztunnel-allowlist.yaml
```

(On macOS, `sed -i ''`.)

**If you get an empty file**, the workload was admitted rather than refused,
usually because a matching allowlist is already installed. Warden only emits an
allowlist when it says no.

Upload:

```bash
gcloud storage cp istio-cni-allowlist.yaml "gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml"
gcloud storage cp ztunnel-allowlist.yaml   "gs://${BUCKET}/istio/${ISTIO_VER}/ztunnel.yaml"
```

---

## Step 3: authorise the paths in organization policy

Every organisation enforces the managed constraint
`container.managed.autopilotPrivilegedAdmission`, which lists the paths clusters
may install allowlists from. By default that is GKE partner and approved
open-source allowlists only. Your `gs://` paths must be added here before the
cluster will accept them.

```bash
cat > autopilot-privileged-admission.yaml <<EOF
name: organizations/${ORG_ID}/policies/container.managed.autopilotPrivilegedAdmission
spec:
  rules:
    - enforce: true
      parameters:
        allowAnyGKEPath: true
        allowPaths:
          - gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml
          - gs://${BUCKET}/istio/${ISTIO_VER}/ztunnel.yaml
EOF

gcloud org-policies set-policy autopilot-privileged-admission.yaml
```

**Keep `allowAnyGKEPath: true`.** Setting it false makes cluster creation and
updates fail unless every cluster passes a conforming
`--autopilot-privileged-admission`, across the whole organisation, not just
Autopilot clusters.

**Do not try a directory prefix.** The docs say the constraint takes "file or
directory paths", but the AllowlistSynchronizer admission check compares paths by
exact string membership, and objects under an authorised directory are refused:

```
[denied by autopilot-allowlist-synchronizer-limitation]: Unauthorized allowlist
path(s) 'gs://.../istio-cni.yaml', 'gs://.../istio-ztunnel.yaml': not found in
authorized path list 'gke://*', 'gs://.../istio/1.30.4/'
```

Name every object individually, here and in the cluster flag. An Istio version
bump therefore costs an org policy edit plus another cluster update.

Checking the policy afterwards is confusing, and this output is normal for a
constraint that is set but not yet propagated to a resource:

```
$ gcloud org-policies describe container.managed.autopilotPrivilegedAdmission --organization=$ORG_ID
NOT_FOUND: A Policy of constraint
constraints/container.managed.autopilotPrivilegedAdmission on resource
organizations/... does not exist.
```

Use `--effective` to see what is actually in force.

---

## Step 4: authorise the paths on the cluster

```bash
gcloud container clusters update "${CLUSTER}" --location "${REGION}" \
  --autopilot-privileged-admission="gke://*,gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml,gs://${BUCKET}/istio/${ISTIO_VER}/ztunnel.yaml"
```

Include `gke://*` explicitly. Setting this flag **replaces** the default
authorisation of every GKE-managed allowlist.

### Expect this to fail the first time

```
ERROR: (gcloud.container.clusters.update) FAILED_PRECONDITION: Operation denied
by org policy: ["constraints/container.managed.autopilotPrivilegedAdmission": ...]
reason: CUSTOM_ORG_POLICY_DENIED
```

This is **propagation, not rejection**. Wait two minutes and run the identical
command again. It will succeed. Do not go debugging your policy; ours was
correct and still produced this.

The update itself takes roughly 20 minutes. Watch it:

```bash
gcloud container operations list --location "${REGION}" --sort-by=~startTime --limit=1
```

Confirm when done:

```bash
$ gcloud container clusters describe "${CLUSTER}" --location "${REGION}" \
    --format='yaml(autopilot.privilegedAdmissionConfig)'
autopilot:
  privilegedAdmissionConfig:
    allowlistPaths:
    - gke://*
    - gs://my-allowlists/istio/1.30.4/istio-cni.yaml
    - gs://my-allowlists/istio/1.30.4/ztunnel.yaml
```

---

## Step 5: install the AllowlistSynchronizer

```bash
cat <<EOF | kubectl apply -f -
apiVersion: auto.gke.io/v1
kind: AllowlistSynchronizer
metadata:
  name: istio-ambient
spec:
  projectNumber: ${PROJECT_NUMBER}
  bucketName: ${BUCKET}
  allowlistPaths:
    - istio/${ISTIO_VER}/istio-cni.yaml
    - istio/${ISTIO_VER}/ztunnel.yaml
EOF
```

`allowlistPaths` here are object paths **within** the bucket, with no `gs://`
prefix. The full `gs://` URLs go in the org policy and the cluster flag.

Verify, and treat this as the real test of steps 3 and 4:

```bash
$ kubectl get workloadallowlists
NAME                   AGE
istio-cni-1.30.4       11s
istio-ztunnel-1.30.4   11s

$ kubectl describe allowlistsynchronizer istio-ambient | sed -n '/Status/,$p'
Status:
  Conditions:
    Message:  Synchronization completed successfully; allowlists up to date
    Reason:   SyncSuccessful
    Status:   True
    Type:     Ready
  Managed Allowlist Status:
    File Path:             istio/1.30.4/istio-cni.yaml
    Phase:                 Installed
    File Path:             istio/1.30.4/ztunnel.yaml
    Phase:                 Installed
```

If a path reports an error here, it is almost always the bucket grant from
step 1.

To update an allowlist later, re-upload to the **same path**. The synchroniser
picks it up; force a check with
`kubectl annotate allowlistsynchronizer istio-ambient resync="$(date +%s)" --overwrite`.

---

## Step 6: grant the critical priority class in istio-system

Both DaemonSets set `priorityClassName: system-node-critical`, correctly: they
are node infrastructure and must not be evicted before application workloads.

Autopilot gates that priority class with a per-namespace `ResourceQuota`, shipped
in `kube-system` and `gke-managed-*` but nowhere else. Without one you get:

```
Error creating: insufficient quota to match these scopes:
  [{PriorityClass In [system-node-critical system-cluster-critical]}]
```

which says nothing about priority classes being the problem.

`--set global.platform=gke` ships a quota for you. To be explicit rather than
relying on a platform flag:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gcp-critical-pods
  namespace: istio-system
spec:
  hard:
    pods: 1G
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values:
          - system-node-critical
          - system-cluster-critical
EOF
```

---

## Step 7: install Istio ambient

Control plane first. `istiod` needs no allowlist; it is an ordinary workload.

```bash
helm upgrade -i istio-base istio/base --version $ISTIO_VER \
  -n istio-system --create-namespace

helm upgrade -i istiod istio/istiod --version $ISTIO_VER \
  -n istio-system --set profile=ambient --wait
```

Then the two privileged DaemonSets, **with exactly the values used in step 2**:

```bash
helm upgrade -i istio-cni istio/cni --version $ISTIO_VER -n istio-system \
  --set profile=ambient \
  --set global.platform=gke \
  --set cni.cniBinDir=/home/kubernetes/bin \
  --set cni.useAppArmorAnnotation=false

helm upgrade -i ztunnel istio/ztunnel --version $ISTIO_VER -n istio-system \
  --set profile=ambient \
  --set global.platform=gke
```

```bash
$ kubectl -n istio-system get ds
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
istio-cni-node   4         4         4       4            4
ztunnel          4         4         4       4            4
```

### If the DaemonSet controller has backed off

After fixing something, the controller may not retry for minutes and its events
will be stale. Force a reconcile rather than waiting:

```bash
kubectl -n istio-system rollout restart ds/istio-cni-node ds/ztunnel
```

---

## Step 8: enrol namespaces and add a waypoint

One label per namespace. No sidecars, and **no pod restarts** — `istio-cni`
captures running pods in place.

```bash
kubectl label namespace my-app istio.io/dataplane-mode=ambient
```

Confirm capture, which is the check people skip. A pod can sit in an "ambient"
namespace and be entirely unmeshed:

```bash
$ kubectl get pods -n my-app \
    -o custom-columns='POD:.metadata.name,REDIRECTION:.metadata.annotations.ambient\.istio\.io/redirection'
POD                        REDIRECTION
my-api-7cbfc65874-nd6nq    enabled
my-worker-68b868b84c-9pqhp enabled
```

ztunnel gives you mTLS and L4 authorization. For **L7** — HTTP methods, paths,
headers — you need a waypoint:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-waypoint
  namespace: my-app
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
EOF

kubectl -n my-app label service my-api istio.io/use-waypoint=my-waypoint
```

```bash
$ kubectl -n my-app get gateway my-waypoint
NAME          CLASS            ADDRESS       PROGRAMMED
my-waypoint   istio-waypoint   10.36.10.51   True
```

The waypoint is an ordinary Envoy pod. It needs no allowlist. Use the
`istio-waypoint` GatewayClass; if your cluster also has vendor waypoint classes
registered, mixing them fails silently.

---

## Step 9: prove it enforces something

Pods Running is not proof. Test with two ServiceAccounts, because ambient policy
keys on workload identity, not IP.

```bash
kubectl -n my-app create sa allowed
kubectl -n my-app create sa denied
kubectl -n my-app run c-allowed --image=curlimages/curl:8.11.0 \
  --overrides='{"spec":{"serviceAccountName":"allowed"}}' -- sleep 100000
kubectl -n my-app run c-denied  --image=curlimages/curl:8.11.0 \
  --overrides='{"spec":{"serviceAccountName":"denied"}}'  -- sleep 100000
```

### mTLS is real

ztunnel reports peer SPIFFE identities on every connection. Read them from its
metrics, scraped **from another pod** (see the debugging note below for why not
`exec`):

```bash
ZIP=$(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].status.podIP}')
kubectl -n my-app exec c-allowed -- curl -s "http://${ZIP}:15020/metrics" \
  | grep -oE '(source|destination)_principal="[^"]*"' | sort -u
```

```
source_principal="spiffe://cluster.local/ns/my-app/sa/allowed"
destination_principal="spiffe://cluster.local/ns/my-app/sa/my-api"
```

### L4 policy, enforced by ztunnel

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-allow-one-identity
  namespace: my-app
spec:
  selector:
    matchLabels:
      app: my-api
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/my-app/sa/allowed"]
EOF
```

```bash
$ kubectl -n my-app exec c-allowed -- curl -s -o /dev/null -w '%{http_code}\n' http://my-api:8080/
200
$ kubectl -n my-app exec c-denied  -- curl -s -o /dev/null -w '%{http_code}\n' http://my-api:8080/
000
```

`000` means the connection was refused, not an HTTP error. Two pods on the same
node with adjacent IPs, different answers, because the decision is on identity.

### L7 policy, enforced by the waypoint

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-deny-writes
  namespace: my-app
spec:
  targetRefs:
    - kind: Service
      group: ""
      name: my-api
  action: DENY
  rules:
    - to:
        - operation:
            methods: ["DELETE", "PUT"]
EOF
```

```bash
$ kubectl -n my-app exec c-allowed -- curl -s -o /dev/null -w '%{http_code}\n' -X GET    http://my-api:8080/
200
$ kubectl -n my-app exec c-allowed -- curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://my-api:8080/
403
```

Note the difference in failure shape: an L4 deny kills the connection (`000`),
an L7 deny returns `403` with the connection intact. That tells you which layer
made the decision.

Finally, delete the policy and confirm traffic returns. Otherwise you have not
proved the policy caused the deny.

---

## Four flags that are not optional

### `--set global.platform=gke`

Adds a `ResourceQuota` allowing `system-node-critical` in `istio-system`. In
1.30.4 that is **all** it does; in particular it does not fix the CNI directory.

### `--set cni.cniBinDir=/home/kubernetes/bin`

Container-Optimized OS mounts `/opt/cni/bin` **read-only**. Without this,
istio-cni passes admission and then crash-loops:

```
$ kubectl -n istio-system logs ds/istio-cni-node | tail -4
error  cni-agent  failed file copy of /opt/cni/bin/istio-cni to /host/opt/cni/bin:
       open /host/opt/cni/bin/istio-cni.tmp.1940367425: read-only file system
warn   hint: some Kubernetes environments require customization of the CNI
       directory. Ensure you properly set global.platform=<name> during installation
error  cni-agent  installer failed: copy binaries: ... read-only file system
Error: copy binaries: ... read-only file system
```

`CrashLoopBackOff` after you have solved admission is easy to misread as an
allowlist problem. It is not. The hint in the log is misleading too:
`global.platform=gke` does not fix it.

### `--set cni.useAppArmorAnnotation=false`

**The most important flag in this guide, and the least obvious.**

By default the cni chart requests AppArmor with the deprecated annotation
`container.apparmor.security.beta.kubernetes.io/install-cni: unconfined`, which
Kubernetes translates into `securityContext.appArmorProfile.type=Unconfined` on
the pod.

**GKE's allowlist generator does not emit `appArmorProfile` for the annotation
form.** The generated allowlist therefore never matches the workload, and
admission fails citing the *original* capability and hostPath violations, with
nothing anywhere pointing at AppArmor:

```
Violations details: {"[denied by autogke-default-linux-capabilities]": ...,
                     "[denied by autogke-no-write-mode-hostpath]": ...}
```

Identical to having installed no allowlist at all. Regenerating does not help.
We found it only by diffing the installed allowlist against the live pod template
field by field.

Setting `useAppArmorAnnotation=false` makes the chart use
`securityContext.appArmorProfile` instead, which the generator **does** read, and
the resulting allowlist matches. Requires Kubernetes 1.30+; on 1.29 or earlier
you must hand-add `appArmorProfile` to the generated allowlist.

### `--set-string ... podAnnotations."cloud\.google\.com/generate-allowlist"=true`

Generation only. Never install with this set. `--set-string` matters: plain
`--set` renders `true` as a boolean and the annotation is invalid.

---

## Debugging: what you give up

**You cannot `kubectl exec` or port-forward into an allowlisted pod.** GKE stamps
`autopilot.gke.io/no-connect: "true"` on every pod admitted through a
`WorkloadAllowlist`, and Warden's `pods/*` `CONNECT` rule then refuses:

```
$ istioctl ztunnel-config workload
error: port forward failed: ... denied the request:
Violations details: {"[denied by autogke-no-pod-connect-limitation]":
["Cannot connect to pod istio-system/ztunnel-7mnr8, with annotation
\"autopilot.gke.io/no-connect\": \"true\"."]}
```

So **`istioctl ztunnel-config` and `istioctl proxy-config` do not work against
ztunnel on Autopilot.** Plan for it: an existing ambient runbook will not
transfer unchanged.

What still works:

- `kubectl logs` on ztunnel and istio-cni, including `--previous`
- ztunnel's metrics on port `15020`, scraped from another pod
- `istioctl proxy-config` against the **waypoint**, which is not allowlisted
- `kubectl describe ds` for admission failures

Which pods are affected:

```bash
kubectl get pods -A -o json | jq -r '
  .items[] | select(.metadata.annotations."autopilot.gke.io/no-connect"=="true")
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

On our cluster that is 10 pods out of 114: `istio-cni-node` and `ztunnel` only.
Everything else, `istiod` and the waypoint included, is a normal debuggable
Autopilot workload.

---

## Error reference

| Symptom | Cause | Fix |
|---|---|---|
| `helm install` succeeds, DaemonSet `0/N`, `denied by autogke-default-linux-capabilities` | No matching allowlist | Steps 2 to 5 |
| Allowlist installed, same capability and hostPath rejection persists | Allowlist does not match. Usually the AppArmor annotation | `--set cni.useAppArmorAnnotation=false`, regenerate |
| `insufficient quota to match these scopes: [{PriorityClass In [system-node-critical ...]}]` | No critical-pods `ResourceQuota` in the namespace | Step 6 |
| Pods `CrashLoopBackOff`, log says `read-only file system` | Wrong CNI bin directory | `--set cni.cniBinDir=/home/kubernetes/bin` |
| `FAILED_PRECONDITION ... CUSTOM_ORG_POLICY_DENIED` on cluster update | Org policy not propagated yet | Wait 2 minutes, re-run unchanged |
| Generated allowlist file is empty | Workload was admitted, so Warden emitted nothing | An allowlist already matches; check `kubectl get workloadallowlists` |
| Synchroniser reports an error on a path | GKE service agent lacks bucket access | Step 1 second grant |
| `denied by autogke-no-pod-connect-limitation` | Pod is allowlisted; exec and port-forward are blocked | Use logs or scrape metrics from another pod |
| Two allowlists for the same workload | GKE timestamps generated names | Rename to something stable before uploading |
| Pods in an ambient namespace, no mTLS | Not actually captured | Check `ambient.istio.io/redirection` |

---

## Maintenance

`matchingCriteria` pins the container image and lists env var names, so the
allowlist is tied to the exact workload:

- **Every Istio version bump** needs regenerated allowlists. Re-run step 2 with
  the new `$ISTIO_VER`, upload to a new path, and add that path to the org
  policy and the cluster flag. A directory prefix does not avoid this: the
  synchroniser compares paths exactly and refuses objects under an authorised
  directory.
- **Any change to the Helm values** used at install time needs regeneration too.
  Generation and installation are coupled; keep the flags in one place.
- **Regenerate, never hand-edit.** A silently non-matching allowlist produces the
  original rejection with no clue that the allowlist is the problem.

---

## What you end up with

On a platform whose documented answer to service mesh was "use a Standard
cluster":

- Workload mTLS between every enrolled pod, on SPIFFE identity derived from the
  ServiceAccount
- L4 authorization on identity rather than IP, which a NetworkPolicy cannot
  express
- L7 authorization on HTTP method, path and header at the waypoint
- No sidecars, and no pod restarts to enrol

Two honest caveats. This is self-managed Istio, not Cloud Service Mesh. And you
give up `exec` into the two node agents, permanently, in exchange.
