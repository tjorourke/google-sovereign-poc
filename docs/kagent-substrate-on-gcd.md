# kagent 1.0 on Agent Substrate in Google Cloud Dedicated (Berlin)

**Status: working.** Verified 2026-10-21 on `eu0:soloio-eval`, cluster `agentic`
(`u-germany-northeast1`): GKE Autopilot 1.36.4-gke.1391000, OSS kagent
1.0.0-alpha16 on Agent Substrate 0.6.0-alpha3 (every agent conversation and
sandbox is a gVisor actor), Solo Enterprise for agentgateway v2026.10.0 in front
of OpenAI `gpt-4.1-mini`. No Istio, AgentRegistry, Keycloak or GPU.

The page has two parts. **Part 1** is the overview: the allowlists GKE needed,
how they were made, the other GCD constraints, and every test with its result.
**Part 2** is every file needed to deploy it, in install order, copied verbatim
from the lab ([`poc/2026-10-kagent-substrate`](../poc/2026-10-kagent-substrate/README.md)),
which remains the source of truth and has the scripts that apply them.

---

# Part 1: overview

## The allowlists: two Substrate workloads, refused by Autopilot without one

GKE Warden (Autopilot's admission control) refused exactly two of Substrate's
workloads. Everything else in Substrate (ate-api-server, ate-controller,
ate-idp-server, atenet-router, atenet-egress, the credential provider, the Pod
Certificate controller, RustFS), kagent, its PostgreSQL and agentgateway is
admitted unaided.

| Workload | Created by | Why it needs host access | Warden's refusal, verbatim | WorkloadAllowlist (exemptions) |
|---|---|---|---|---|
| `atelet` DaemonSet, `ate-system` | the Substrate Helm chart (`kagent install`) | Substrate's node agent: stages actor runtimes, sandbox assets and snapshots under `/var/lib/ate` (shared with the workers), uses the kubelet's plugin and device-plugin directories, mounts the host's `/dev` read-only | `[denied by autogke-no-write-mode-hostpath]` hostPath volume `ate-base` / `kubelet-plugins` / `device-plugins` in container atelet "is accessed in write mode; disallowed in Autopilot"; `host-dev` "uses path /dev which is not allowed in Autopilot. Allowed path prefixes for hostPath volumes are: [/var/log/]"; `ate-base` in init container objectstore-plugin "is accessed in write mode" | `substrate-atelet-0.6.0-alpha3` (`autogke-no-write-mode-hostpath`) |
| gVisor worker Deployment `kagent/kagent-default` (one per WorkerPool) | Substrate's `ate-controller` at runtime, from kagent's WorkerPool | each actor is a `runsc` sandbox: setting up its network and mounts needs `NET_ADMIN` and `SYS_ADMIN`; actor files live in the node's `/var/lib/ate` | `[denied by autogke-default-linux-capabilities]` "linux capability 'NET_ADMIN,SYS_ADMIN' on container 'worker' not allowed; Autopilot only allows the capabilities: 'AUDIT_WRITE,CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,MKNOD,NET_BIND_SERVICE,NET_RAW,SETFCAP,SETGID,SETPCAP,SETUID,SYS_CHROOT,SYS_PTRACE'"; `[denied by autogke-no-write-mode-hostpath]` hostPath volume `ate-base` in container worker "is accessed in write mode" | `substrate-ateworker-gvisor-0.6.0-alpha3` (`autogke-default-linux-capabilities`, `autogke-no-write-mode-hostpath`) |

The full refusals are in [`evidence/warden-refusals-2026-10-21.txt`](../poc/2026-10-kagent-substrate/evidence/warden-refusals-2026-10-21.txt).

**What Warden did not object to**: atelet and the workers running as root
(`runAsUser: 0`), atelet's `hostPort: 21998`, atelet's read-only mounts and its
`DAC_OVERRIDE` capability, the workers' eleven other added capabilities
(`SYS_CHROOT`, `SYS_PTRACE`, `SETUID`, `SETGID`, `SETPCAP`, `DAC_OVERRIDE`,
`FOWNER`, `CHOWN`, `MKNOD`, `NET_RAW`, `SETFCAP`, all inside Autopilot's
default set), and the workers' `Unconfined` seccomp and AppArmor profiles.

### How they were generated and installed

1. **Paths authorised before the cluster existed.** Autopilot admits an
   allowlist only from an object path listed *exactly* (a directory prefix is
   not honoured) in two places: the org policy
   `container.managed.autopilotPrivilegedAdmission` (organisation-wide; it keeps
   `allowAnyGKEPath: true` for GKE's own partner allowlists) and the cluster's
   `autopilot_privileged_admission`. Adding a path later costs an org-policy edit
   plus a ~20 minute cluster update, so the atelet and worker paths, and two
   spares, were set at creation ([2.1](#21-cluster-opentofu), [2.2](#22-org-policy-allowlist-paths)).
2. **Warden writes the allowlist.** A pod carrying the annotation
   `cloud.google.com/generate-allowlist: "true"` is still refused, but the
   refusal then contains a ready-made `WorkloadAllowlist` pinned to that exact
   spec (images, args, env names, security context, volumes).
   - *atelet*: render the Substrate chart with the exact install values
     (`helm template … --set postgres.clientCertificates.enabled=true -f substrate-values.yaml`),
     add the annotation, and `kubectl apply --dry-run=server`. Nothing is
     created; the error carries the allowlist.
   - *worker*: its Deployment is created at runtime by `ate-controller`, so the
     refusal reaches only that controller's log. kagent's values put the
     annotation on the WorkerPool's pod template; the script reads the generated
     allowlist out of the `ate-controller` log.
3. **Rename and upload**: each is renamed to a versioned name and copied to
   `gs://agentic-allowlist/substrate/0.6.0-alpha3/{atelet,ateworker-gvisor}.yaml`.
4. **Install with an `AllowlistSynchronizer`** ([2.6](#26-workloadallowlists-and-the-synchronizer)),
   which copies listed bucket objects into the cluster as `WorkloadAllowlist`s.
   *Gotcha:* it re-reads files only when its own spec changes. A file
   re-uploaded to an existing path sat unsynced for over 7 minutes, then
   installed within 5 seconds of the path list changing; the script flips the
   list order when it is otherwise unchanged.
5. **Order**: atelet's allowlist before `kagent install` (the Substrate release
   waits for the DaemonSet); the worker's after it (its Deployment only exists
   once kagent creates the WorkerPool), then the pool is touched to reconcile.

**Consequences.** GKE stamps `autopilot.gke.io/no-connect: "true"` on allowlisted
pods: atelet and the workers cannot be exec'd, attached or port-forwarded
(`kubectl logs` works). An allowlist pins the spec, so any Substrate version
bump or values change that reaches either pod means regenerating both, at new
versioned paths that must first be added to the org policy and the cluster.
Changes that reach neither pod need nothing: this lab later changed
ate-api-server's flags and the RustFS bucket Job, `helm template` showed only
those lines changing, and the atelet DaemonSet stayed at generation 1.

Automated by [`scripts/20-allowlists.sh`](../poc/2026-10-kagent-substrate/scripts/20-allowlists.sh) (`atelet`, `worker`, `sync`, `status`).

## The other GCD constraints, and what solved each

| Constraint in GCD | Effect on Substrate / kagent | Solution ([Part 2](#part-2-every-file-needed-in-install-order)) |
|---|---|---|
| Autopilot is the only GKE mode | atelet and workers refused (above) | WorkloadAllowlists |
| Substrate needs `PodCertificateRequest` and `ClusterTrustBundle`: GA in 1.37, beta in 1.36; Berlin's newest is 1.36.4 | install hangs at "Waiting for podcertificate ClusterTrustBundles" | both beta APIs enabled **at cluster creation** (GKE ignores a later change) |
| Hyperdisk Balanced is the only disk type; 4 GiB floor | `kagent install`'s 500Mi PostgreSQL claim never provisions | `MutatingAdmissionPolicy` raising claims to 4Gi at creation, shrink becomes a no-op |
| Autopilot raises small CPU requests (the bucket Job's 10m was stored as 50m) | the chart's RustFS bucket Job no longer matches what is stored, so every later upgrade of the release (a re-run of `kagent install` included) fails on its immutable pod template | `rustfs.bucketInit.resources` set to exactly what Autopilot stores |
| Substrate's API admits only its bootstrap owners; `kagent install` names only kagent's controller, by Pod Certificate SPIFFE ID | `kubectl ate` refused, whatever token it sends | explicit operator principal `system:serviceaccount:ate-system:ate-operator` |
| No GPUs wanted (the old cluster ran an H100 around the clock) | Autopilot would provision accelerator nodes on demand | `ValidatingAdmissionPolicy` refusing accelerator requests and selectors |
| No nested virtualisation on Autopilot | Substrate's microVM sandbox class cannot run | gVisor class only (the default) |
| Images | public registries reachable over Cloud NAT | pulled directly; mirroring into the in-universe Artifact Registry would need atelet's image credential provider (two more host mounts, so a regenerated allowlist) |

## Every test, and its result

All on 2026-10-21. Evidence paths are under
[`poc/2026-10-kagent-substrate/evidence/`](../poc/2026-10-kagent-substrate/evidence/).
`60-verify.sh` passed 13/13 at 15:15Z, 15:54Z and 16:22Z (after the Substrate
upgrade below); its first run, at 15:14Z, failed one check before the sandbox
agent's prompt was tightened. `70-substrate-behaviours.sh` passed 22/22 at 16:19Z
and again at 16:35Z, after `kagent install` had been re-run over the live install.

| # | Test | Result | Evidence |
|---|---|---|---|
| 1 | Cluster serves the certificate beta APIs and the allowlist paths | `clustertrustbundles`, `podcertificaterequests` served as `certificates.k8s.io/v1beta1`; five admission paths | `cluster-2026-10-21.txt` |
| 2 | Substrate without allowlists | atelet and worker refused, reasons above | `warden-refusals-2026-10-21.txt` |
| 3 | Control planes; atelet and workers admitted by their allowlists | all Substrate Deployments available; atelet on every node; 2/2 workers, `no-connect: true` | `verify-*.txt`, `gvisor-actors-2026-10-21.txt` |
| 4 | GPU guard | H100 pod refused by `deny-gpu-workloads` | `verify-*.txt` |
| 5 | agentgateway holds the only OpenAI key | in-cluster call with a placeholder key: HTTP 200 from `gpt-4.1-mini` | `30-agentgateway.sh` run; lab README |
| 6 | Agent conversation: Substrate actor (gVisor) → agentgateway → OpenAI | `trustusbank-assistant` answered; agentgateway logged the completions | `verify-*.txt` |
| 7 | A sandbox runs under gVisor, not the node kernel | `uname`: `Linux 4.19.0-gvisor`; `dmesg`: `Starting gVisor...`; node `6.12.105+` (COS); a `runsc` launch per actor in the worker logs | `verify-*.txt`, `gvisor-actors-2026-10-21.txt` |
| 8 | Actor state survives suspend → resume | file written before suspend read back after resume | `verify-*.txt` |
| 9 | An agent drives a sandbox through kagent's MCP tools | `trustusbank-sandbox-ops` created a sandbox, ran `uname -sr && dmesg`, reported gVisor | `verify-*.txt` |
| 10 | Substrate's own records (PostgreSQL schema `substrate`) | 1 atespace, 4 ActorTemplates, 4 snapshot tags, 6 session actors, no worker assignments (all suspended when idle) | `substrate-records-2026-10-21.txt` |
| 11 | Substrate's API through `kubectl ate` | shared `ate-client` identity and a kagent-controller token both `PermissionDenied`; as `ate-operator`: atespaces, templates, actors with state, tags, workers listed | `substrate-api-2026-10-21.txt`, `behaviours-*.txt` |
| 12 | Multiplexing: 20 conversations invoked at once, two rounds (three runs) | 20 actors, at most **8 running at once**: 4 per worker, as each actor reserves 1 CPU of a worker's 4 (Substrate's own view at the peak, on each worker: `ACTORS 4/1000  CPU 4/4  MEMORY 4Gi/8Gi`). All 40 invocations answered in every run. Resume (Substrate `resuming` → `running`): **p50 343–357 ms, p95 446–531 ms, max 582 ms** over 120 resumes. End to end with the model call: round 1 p50 13.4–14.2 s (queueing for a worker), round 2 p50 5.4–6.3 s | `multiplex-2026-10-21T1635Z/report.txt`, `…T1619Z`, `…T1613Z` |
| 13 | What happens when no worker has room | 17–20 of 57–60 calls per run refused at resume (`ResourceExhausted: no worker has room for the actor`), answered UNAVAILABLE at once: atenet-router did not hold them. kagent's gateway reported each as not accepted (`KAGENT_SEND_NOT_ACCEPTED`) and the kagent CLI re-sent it (every 100 ms, up to 30 s), so no invocation failed | same |
| 14 | An actor resumes on a different worker than it ran on | 5, 7 and 10 actors in the three runs came back on the other worker in round 2; each one's round-2 reply summarised its own round-1 answer, so the conversation moved with the snapshot | same |
| 15 | Session checkpoint and fork (kagent MCP `create_session_checkpoint`, `fork_session`) | codeword planted, checkpoint READY, second codeword planted after it; the fork recalls only `KESTREL-42`, the original both. The checkpoint is an atespace-scoped Substrate tag; the fork a new actor | `checkpoint-fork-2026-10-21.txt`, `behaviours-*.txt` |
| 16 | EgressPolicy: deny by default, then one origin | no policy: `example.com` and `api.github.com` do not even resolve (`bad address`), an IP literal gets **403** from atenet-egress (`actor egress policy denied destination`). After adding the policy to the SandboxTemplate, the **same running sandbox** fetched `https://example.com` (rc 0); `api.github.com` still closed | `behaviours-*.txt` |
| 17 | Re-running `kagent install` over the live install | clean on the first attempt, twice (after the bucket-Job fix; before it, the same upgrade failed); the operator principal kept, the atelet DaemonSet unchanged (generation 1) | `reinstall-2026-10-21.txt` |
| 18 | microVM sandbox class | not attempted: Autopilot has no nested virtualisation | — |

Re-run them with `scripts/60-verify.sh` and
`scripts/70-substrate-behaviours.sh [api|multiplex|fork|egress|all]`.

## Findings worth knowing

- **Capacity is CPU, not actor count.** Each worker advertises room for 1000
  actors, but a running actor reserves its template's limits (1 CPU / 1 GiB
  here) out of the worker pod's own limits (4 CPU / 8 GiB), so the pod size is
  the concurrency. Idle actors suspended within seconds of replying.
- **No request parking in this router.** Substrate's request-parking design
  describes the Envoy ext_proc router; 0.6.0-alpha3's atenet-router is
  agentgateway-based and refused at once. kagent's own CLI recovers through the
  `KAGENT_SEND_NOT_ACCEPTED` retry contract; any other A2A client of kagent must
  honour it too, or it will see the error under load.
- **Sandbox egress is closed at two layers**: names no policy grants do not
  resolve (the sandbox's only DNS server and route is `169.254.17.1`), and an IP
  literal still meets the egress gateway. Policy changes reach running sandboxes
  without a restart.
- **`kubectl ate` needs an operator principal** that `kagent install` does not
  create, and the shared `ate-client` fallback should not be one (Substrate's
  own advice outside development).
- Earlier, on the same day: `kagent install`'s 500Mi PostgreSQL claim cannot
  provision on Hyperdisk Balanced (worth raising with kagent: make it
  configurable); Substrate's CAs last a year and nothing renews them (re-run
  per the kagent Helm README before 2027-10-21).

---

# Part 2: every file needed, in install order

Run order, once the cluster exists:
`10-cluster.sh` → `15-gpu-guard.sh` → `20-allowlists.sh atelet` →
`30-agentgateway.sh` → `40-kagent.sh` (runs `20-allowlists.sh worker`) →
`50-agents.sh` → `60-verify.sh` → `70-substrate-behaviours.sh`
([`scripts/run-all.sh`](../poc/2026-10-kagent-substrate/scripts/run-all.sh)).
Secrets (`AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`) come from the
environment and appear in no file. Paths in commands are relative to
`poc/2026-10-kagent-substrate/`.

## 2.1 Cluster (OpenTofu)

The profile settings this lab depends on. GKE honours `k8s_beta_apis` only at
creation, and the admission paths should be set then too.

[`infra/tofu/profiles/gcd-autopilot.tfvars`](../infra/tofu/profiles/gcd-autopilot.tfvars) (excerpt):

```hcl
cluster_name = "agentic"
# 2026-10-21 rebuild for kagent 1.0 on Agent Substrate (poc/2026-10-kagent-substrate).
# Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs: GA and
# served by default on 1.37, beta on 1.36. Berlin offers nothing newer than
# 1.36.4-gke.1391000 (the RAPID default), so this pins that build and enables
# both beta APIs below. RAPID is still not where a customer-facing environment
# should live; it is here because no other channel has 1.36 as its default.
release_channel    = "RAPID"
min_master_version = "1.36.4-gke.1391000"

# Creation-time only: GKE ignores a later change, so editing this means
# recreating the cluster. Empty it once Berlin serves 1.37.
k8s_beta_apis = [
  "certificates.k8s.io/v1beta1/podcertificaterequests",
  "certificates.k8s.io/v1beta1/clustertrustbundles",
]

# Agent Substrate's atelet DaemonSet and gVisor worker pods, admitted through
# WorkloadAllowlists that poc/2026-10-kagent-substrate generates. Each path must
# also be in the org policy (that lab's allowlists/orgpolicy-*.yaml), and must
# be set here at creation to avoid a ~20 minute cluster update. The spares are
# authorised but empty until needed. Istio's paths are gone: no mesh this time.
autopilot_privileged_admission = [
  "gke://*",
  "gs://agentic-allowlist/substrate/0.6.0-alpha3/atelet.yaml",
  "gs://agentic-allowlist/substrate/0.6.0-alpha3/ateworker-gvisor.yaml",
  "gs://agentic-allowlist/substrate/spare-1.yaml",
  "gs://agentic-allowlist/substrate/spare-2.yaml",
]
```

How the module applies them ([`infra/tofu/modules/gke-autopilot/main.tf`](../infra/tofu/modules/gke-autopilot/main.tf), excerpt):

```hcl
resource "google_container_cluster" "this" {
  enable_autopilot               = true
  autopilot_privileged_admission = var.autopilot_privileged_admission

  # GKE honours this only at CREATION: added later, the update succeeds and
  # the APIs are still not served, so the cluster has to be recreated.
  dynamic "enable_k8s_beta_apis" {
    for_each = length(var.k8s_beta_apis) > 0 ? [1] : []
    content {
      enabled_apis = var.k8s_beta_apis
    }
  }
  # ...
}
```

Recreate the cluster with the replace in the header of
[`scripts/10-cluster.sh`](../poc/2026-10-kagent-substrate/scripts/10-cluster.sh).

## 2.2 Org policy: allowlist paths

Organisation-scoped; set with `gcloud org-policies set-policy`. The `istio/`
paths are the earlier ambient lab's.

[`poc/2026-10-kagent-substrate/allowlists/orgpolicy-autopilot-privileged-admission.yaml`](../poc/2026-10-kagent-substrate/allowlists/orgpolicy-autopilot-privileged-admission.yaml):

```yaml
# Organisation-scoped: this affects every GKE cluster in the org.
#
# Extends the policy 63-allowlist-install.sh wrote for Istio rather than
# replacing it. Paths are EXACT objects; a directory prefix is not honoured
# (feedback/google/evidence/berlin-allowlist-path-prefix-not-honoured-2026-09-04.txt).
#
#   istio/...                      the earlier ambient lab, kept so it can rebuild
#   substrate/0.6.0-alpha3/...     Agent Substrate: atelet DaemonSet, gVisor workers
#   substrate/spare-*.yaml         authorised in advance, unused until needed: adding
#                                  a path later costs an org policy edit plus a
#                                  ~20 minute cluster update
#
# allowAnyGKEPath: true keeps GKE's own partner allowlists. Do not change it.
name: organizations/560780939237871/policies/container.managed.autopilotPrivilegedAdmission
spec:
  rules:
    - enforce: true
      parameters:
        allowAnyGKEPath: true
        allowPaths:
          - gs://agentic-allowlist/istio/1.30.4/istio-cni.yaml
          - gs://agentic-allowlist/istio/1.30.4/istio-ztunnel.yaml
          - gs://agentic-allowlist/substrate/0.6.0-alpha3/atelet.yaml
          - gs://agentic-allowlist/substrate/0.6.0-alpha3/ateworker-gvisor.yaml
          - gs://agentic-allowlist/substrate/spare-1.yaml
          - gs://agentic-allowlist/substrate/spare-2.yaml
```

## 2.3 GPU guard

[`poc/2026-10-kagent-substrate/yaml/gpu-guard.yaml`](../poc/2026-10-kagent-substrate/yaml/gpu-guard.yaml):

```yaml
# No GPUs on this cluster, enforced rather than merely absent.
#
# Autopilot provisions an accelerator node for any pod that asks for one: the
# previous cluster ran an a3-edgegpu-8g-nolssd (H100) node for Gemma around the
# clock. With no Node pools to remove, the only cluster-side lever is admission,
# so this policy refuses any workload that requests an accelerator resource or
# selects accelerator nodes.
#
# Checked on the workload objects as well as Pods so a Deployment is refused at
# `kubectl apply`, where someone will see it, rather than only as a ReplicaSet
# event. GKE's own namespaces are exempt so the policy can never block a
# managed component.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-gpu-workloads
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - apiGroups: ["batch"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["jobs", "cronjobs"]
  matchConditions:
    - name: not-a-gke-managed-namespace
      expression: >-
        !(request.namespace in ['kube-system', 'kube-public', 'kube-node-lease', 'gmp-system', 'gmp-public'])
        && !request.namespace.startsWith('gke-')
  variables:
    - name: podSpec
      expression: >-
        object.kind == 'Pod' ? object.spec :
        object.kind == 'CronJob' ? object.spec.jobTemplate.spec.template.spec :
        object.spec.template.spec
    - name: containers
      expression: >-
        variables.podSpec.containers +
        (has(variables.podSpec.initContainers) ? variables.podSpec.initContainers : [])
    - name: acceleratorResource
      expression: >-
        ['nvidia.com/', 'amd.com/', 'google.com/tpu']
  validations:
    - expression: >-
        variables.containers.all(c,
          !has(c.resources) || (
            (!has(c.resources.limits) || !c.resources.limits.exists(k,
              variables.acceleratorResource.exists(p, k.startsWith(p)))) &&
            (!has(c.resources.requests) || !c.resources.requests.exists(k,
              variables.acceleratorResource.exists(p, k.startsWith(p))))))
      reason: Forbidden
      message: >-
        GPU access is disabled on this cluster: containers may not request
        accelerator resources (nvidia.com/*, amd.com/*, google.com/tpu).
    - expression: >-
        !has(variables.podSpec.nodeSelector) ||
        !variables.podSpec.nodeSelector.exists(k,
          k in ['cloud.google.com/gke-accelerator', 'cloud.google.com/gke-tpu-accelerator',
                'cloud.google.com/gke-accelerator-count'])
      reason: Forbidden
      message: >-
        GPU access is disabled on this cluster: workloads may not select
        accelerator nodes.
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-gpu-workloads
spec:
  policyName: deny-gpu-workloads
  validationActions: [Deny]
```

## 2.4 Hyperdisk floor for PVCs

[`poc/2026-10-kagent-substrate/yaml/pvc-floor.yaml`](../poc/2026-10-kagent-substrate/yaml/pvc-floor.yaml):

```yaml
# Hyperdisk Balanced is the only disk type in GCD, and it has a 4 GiB floor:
# a smaller claim fails with "Volume provisioning failed with infeasible error
# ... InvalidArgument" and the pod waits for ever. `kagent install` creates its
# development PostgreSQL with a 500Mi claim (fine on kind, impossible here).
#
# This raises any claim below the floor to the floor at creation, and makes a
# later attempt to shrink a claim (the CLI re-applying its 500Mi manifest on a
# re-run) a no-op instead of an error. MutatingAdmissionPolicy is GA in 1.36.
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: hyperdisk-pvc-floor
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["persistentvolumeclaims"]
  matchConditions:
    - name: not-a-gke-managed-namespace
      expression: >-
        !(request.namespace in ['kube-system', 'kube-public', 'gmp-system', 'gmp-public'])
        && !request.namespace.startsWith('gke-')
    - name: has-storage-request
      expression: >-
        has(object.spec.resources) && has(object.spec.resources.requests)
        && 'storage' in object.spec.resources.requests
  variables:
    - name: requested
      expression: string(object.spec.resources.requests['storage'])
    - name: previous
      expression: >-
        request.operation == 'UPDATE' && oldObject != null && has(oldObject.spec.resources)
        && has(oldObject.spec.resources.requests) && 'storage' in oldObject.spec.resources.requests
        ? string(oldObject.spec.resources.requests['storage']) : ''
    # Raise only at CREATE. On UPDATE a claim's request may not grow unless it
    # is bound, so raising an existing claim would make EVERY update to it fail,
    # finalizer removal included: the claim could then never be deleted. On
    # UPDATE, only turn a shrink back into "unchanged".
    - name: target
      expression: >-
        request.operation == 'CREATE'
        ? (quantity(variables.requested).isLessThan(quantity('4Gi')) ? '4Gi' : '')
        : (variables.previous != '' && quantity(variables.requested).isLessThan(quantity(variables.previous))
           ? variables.previous : '')
  mutations:
    - patchType: JSONPatch
      jsonPatch:
        expression: >-
          variables.target == '' ? [] :
          [JSONPatch{op: 'replace', path: '/spec/resources/requests/storage', value: variables.target}]
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: hyperdisk-pvc-floor
spec:
  policyName: hyperdisk-pvc-floor
```

## 2.5 agentgateway (Enterprise) in front of OpenAI

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
CHARTS=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
helm upgrade --install enterprise-agentgateway-crds $CHARTS/enterprise-agentgateway-crds \
  -n agentgateway-system --create-namespace --version v2026.10.0 --wait
helm upgrade --install enterprise-agentgateway $CHARTS/enterprise-agentgateway \
  -n agentgateway-system --version v2026.10.0 \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" --wait
# The only copy of the OpenAI key; agentgateway sends it upstream verbatim.
kubectl -n agentgateway-system create secret generic openai-secret \
  --from-literal=Authorization="Bearer $OPENAI_API_KEY"
```

Then the Gateway, backend and route (`__OPENAI_MODEL__` is replaced with
`gpt-4.1-mini` by [`30-agentgateway.sh`](../poc/2026-10-kagent-substrate/scripts/30-agentgateway.sh)):

[`poc/2026-10-kagent-substrate/yaml/agentgateway.yaml`](../poc/2026-10-kagent-substrate/yaml/agentgateway.yaml):

```yaml
# agentgateway in front of the model: the one governed hop between every agent
# actor and the LLM. With no GPUs on this cluster the model is OpenAI, reached
# over Cloud NAT; the API key exists only in the openai-secret Secret below
# (created by 30-agentgateway.sh) and the gateway adds it upstream. Agents send
# a placeholder.
#
# ClusterIP only. Agents reach it in-cluster; nothing here needs a public IP.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  service:
    spec:
      type: ClusterIP
  deployment:
    metadata:
      labels:
        company: trustusbank
    spec:
      template:
        metadata:
          labels:
            company: trustusbank
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: agentgateway-proxy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        # Pinned here, so a caller cannot switch itself onto a pricier model.
        model: __OPENAI_MODEL__
  policies:
    auth:
      secretRef:
        name: openai-secret
---
# OpenAI-shaped path: kagent's OpenAI clients post to <baseUrl>/chat/completions
# with baseUrl .../v1 (yaml/kagent-values.yaml, yaml/agents.yaml).
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
  rules:
    - matches:
        - path: { type: PathPrefix, value: /v1 }
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: openai
```

## 2.6 WorkloadAllowlists and the synchronizer

Generated by Warden (see [How they were generated](#how-they-were-generated-and-installed)),
renamed, uploaded to `gs://agentic-allowlist/substrate/0.6.0-alpha3/`, and
installed by the synchronizer. Do not hand-edit: they must match the pods
exactly, so regenerate with `20-allowlists.sh`.

atelet, before `kagent install`:

[`poc/2026-10-kagent-substrate/allowlists/atelet.yaml`](../poc/2026-10-kagent-substrate/allowlists/atelet.yaml):

```yaml
apiVersion: auto.gke.io/v1
kind: WorkloadAllowlist
metadata:
    name: substrate-atelet-0.6.0-alpha3
    annotations:
        autopilot.gke.io/no-connect: "true"
exemptions:
    - autogke-no-write-mode-hostpath
matchingCriteria:
    initContainers:
        - name: objectstore-plugin
          image: ghcr.io/kagent-dev/substrate/objectstore-plugin:v0.6.0-alpha3
          args:
            - node
            - --socket=/run/objectstore-plugin/node.sock
            - --root=/var/lib/ate
            - --asset-staging-dir=/var/lib/objectstore-plugin/asset-staging
            - --asset-staging-capacity=8Gi
          env:
            - name: ATE_STORAGE_BACKEND
            - name: AWS_REGION
            - name: AWS_ENDPOINT_URL
            - name: AWS_S3_USE_PATH_STYLE
            - name: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
          securityContext:
            capabilities:
                drop:
                    - ALL
          startupProbe:
            exec:
                command:
                    - /ko-app/objectstore-plugin
                    - healthcheck
                    - --socket=/run/objectstore-plugin/node.sock
          volumeMounts:
            - mountPath: /var/lib/ate
              name: ate-base
            - mountPath: /run/objectstore-plugin
              name: objectstore-plugin
            - mountPath: /var/lib/objectstore-plugin/asset-staging
              name: asset-staging
    containers:
        - name: atelet
          image: ghcr.io/kagent-dev/substrate/atelet:v0.6.0-alpha3
          args:
            - --preview=
            - --objectstore-plugin-socket=/run/objectstore-plugin/node.sock
            - --grpc-server-cred-bundle=/run/podidentity.podcert.ate.dev/credential-bundle.pem
            - --client-ca-certs=/run/podidentity.podcert.ate.dev/trust-bundle.pem
            - --ateapi-ca-file=/run/servicedns.podcert.ate.dev/trust-bundle.pem
          env:
            - name: NODE_NAME
            - name: POD_NAME
            - name: POD_NAMESPACE
            - name: POD_UID
            - name: OTEL_RESOURCE_ATTRIBUTES
          securityContext:
            capabilities:
                add:
                    - DAC_OVERRIDE
                drop:
                    - ALL
          volumeMounts:
            - mountPath: /run/objectstore-plugin
              name: objectstore-plugin
            - mountPath: /var/lib/ate
              name: ate-base
            - mountPath: /run/podidentity.podcert.ate.dev
              name: podidentity
              readOnly: true
            - mountPath: /run/servicedns.podcert.ate.dev
              name: servicedns-ca
              readOnly: true
            - mountPath: /var/lib/kubelet/plugins
              name: kubelet-plugins
            - mountPath: /var/lib/kubelet/device-plugins
              name: device-plugins
            - mountPath: /host/dev
              name: host-dev
              readOnly: true
    volumes:
        - name: objectstore-plugin
        - name: asset-staging
        - hostPath:
            path: /var/lib/ate
          name: ate-base
        - hostPath:
            path: /var/lib/kubelet/plugins
          name: kubelet-plugins
        - hostPath:
            path: /var/lib/kubelet/device-plugins
          name: device-plugins
        - hostPath:
            path: /dev
          name: host-dev
        - name: podidentity
        - name: servicedns-ca
```

gVisor worker, after `kagent install` (from the `ate-controller` log):

[`poc/2026-10-kagent-substrate/allowlists/ateworker-gvisor.yaml`](../poc/2026-10-kagent-substrate/allowlists/ateworker-gvisor.yaml):

```yaml
apiVersion: auto.gke.io/v1
kind: WorkloadAllowlist
metadata:
    name: substrate-ateworker-gvisor-0.6.0-alpha3
    annotations:
        autopilot.gke.io/no-connect: "true"
exemptions:
    - autogke-default-linux-capabilities
    - autogke-no-write-mode-hostpath
matchingCriteria:
    containers:
        - name: worker
          image: ghcr.io/kagent-dev/substrate/ateworker-gvisor:v0.6.0-alpha3
          args:
            - --pod-uid=$(POD_UID)
            - --atunnel-listen-address=:443
            - --atunnel-connect-listen-address=:8443
            - --atunnel-credential-bundle=/run/podidentity.podcert.ate.dev/credential-bundle.pem
            - --atunnel-trust-bundle=/run/podidentity.podcert.ate.dev/trust-bundle.pem
            - --atunnel-client-identity=spiffe://cluster.local/ns/ate-system/sa/atenet-router
            - --atunnel-egress-listen-address=0.0.0.0:15001
            - --atunnel-egress-trust-bundle=/run/servicedns.podcert.ate.dev/trust-bundle.pem
            - --dns-egress-policy=enforce-in-atunnel
            - --preview=
          env:
            - name: POD_UID
            - name: POD_NAMESPACE
            - name: WORKER_POOL_NAME
          securityContext:
            appArmorProfile:
                type: Unconfined
            capabilities:
                add:
                    - NET_ADMIN
                    - SYS_ADMIN
                    - SYS_CHROOT
                    - SYS_PTRACE
                    - SETUID
                    - SETGID
                    - SETPCAP
                    - DAC_OVERRIDE
                    - FOWNER
                    - CHOWN
                    - MKNOD
                    - NET_RAW
                    - SETFCAP
                drop:
                    - ALL
            privileged: false
          volumeMounts:
            - mountPath: /run/worker-capacity
              name: worker-capacity
              readOnly: true
            - mountPath: /var/lib/ate
              name: ate-base
            - mountPath: /run/podidentity.podcert.ate.dev
              name: atunnel-identity
              readOnly: true
            - mountPath: /run/servicedns.podcert.ate.dev
              name: atunnel-egress-trust
              readOnly: true
    volumes:
        - name: worker-capacity
        - hostPath:
            path: /var/lib/ate
          name: ate-base
        - name: atunnel-identity
        - name: atunnel-egress-trust
```

The synchronizer (`20-allowlists.sh sync` writes it):

[`poc/2026-10-kagent-substrate/allowlists/allowlistsynchronizer.yaml`](../poc/2026-10-kagent-substrate/allowlists/allowlistsynchronizer.yaml):

```yaml
apiVersion: auto.gke.io/v1
kind: AllowlistSynchronizer
metadata:
  name: substrate
spec:
  projectNumber: 560780937444745
  bucketName: agentic-allowlist
  allowlistPaths:
    - substrate/0.6.0-alpha3/atelet.yaml
    - substrate/0.6.0-alpha3/ateworker-gvisor.yaml
```

## 2.7 kagent 1.0 with Agent Substrate

`kagent install` (the kagent docs' installer) installs kagent's and
Substrate's CRDs, Substrate's CAs and API authentication config, the Pod
Certificate controller, a development PostgreSQL (logins by Pod Certificate,
no passwords), Substrate in `ate-system`, and kagent with a gVisor WorkerPool:

```bash
kubectl apply -f yaml/pvc-floor.yaml            # 2.4, before the installer's PostgreSQL claim
OPENAI_API_KEY=placeholder-the-key-is-in-agentgateway \
  kagent --config yaml/kagent-cli-config.yaml install --namespace kagent
kubectl apply -f yaml/ate-operator.yaml
```

The CLI configuration:

[`poc/2026-10-kagent-substrate/yaml/kagent-cli-config.yaml`](../poc/2026-10-kagent-substrate/yaml/kagent-cli-config.yaml):

```yaml
# kagent CLI configuration for `kagent install` (scripts/40-kagent.sh).
# Paths are relative to this file. No secrets here: the CLI reads the provider
# key from the environment, and 40-kagent.sh passes a placeholder because the
# real OpenAI key lives only in agentgateway.
install:
  defaultModelProvider: OpenAI
  kagent:
    valuesFiles: [kagent-values.yaml]
  substrate:
    valuesFiles: [substrate-values.yaml]
```

kagent values (provider through agentgateway, sandbox guest, the WorkerPool
size and its generate-allowlist annotation):

[`poc/2026-10-kagent-substrate/yaml/kagent-values.yaml`](../poc/2026-10-kagent-substrate/yaml/kagent-values.yaml):

```yaml
# kagent 1.0 chart values, applied by `kagent install` over its own defaults.

providers:
  openAI:
    # The generated default ModelConfig goes through agentgateway, which holds
    # the real OpenAI key and adds it upstream. The kagent-openai Secret only
    # ever holds a placeholder. Full DNS name: Substrate only resolves names
    # that match an actor's egress policy, and short names are not inferred.
    config:
      baseUrl: http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1

config:
  sandboxes:
    # Standalone sandboxes need a digest-pinned guest; empty disables them.
    guestImage: ghcr.io/kagent-dev/kagent/sandbox-guest@sha256:d3c444e3f5472598ff520255b72cfcb9ecdf22815fd87747315aeaf0520801c3

substrateWorkerPool:
  # Worker pods host the gVisor sandboxes. Each actor reserves its runtime
  # limits (1 CPU / 1 GiB by default) out of its worker's own limits, which
  # atelet reads through the downward API, so the pod size IS the capacity.
  replicas: 2
  template:
    annotations:
      # GKE Warden returns a ready-made WorkloadAllowlist in its rejection when
      # the pod carries this. The worker Deployment is created at runtime by
      # Substrate's controller, so this is how 20-allowlists.sh gets the exact
      # spec. Harmless once an allowlist admits the pod.
      cloud.google.com/generate-allowlist: "true"
    resources:
      requests:
        cpu: "2"
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 8Gi

# Needs a Grafana this cluster does not have, and pulls from Docker Hub.
grafana-mcp:
  enabled: false
```

Substrate values. Neither setting reaches the atelet pod, so its allowlist
stands (a change that did would need a regenerated one):

[`poc/2026-10-kagent-substrate/yaml/substrate-values.yaml`](../poc/2026-10-kagent-substrate/yaml/substrate-values.yaml):

```yaml
# Agent Substrate chart values. Read by `kagent install` (through
# kagent-cli-config.yaml) AND by 20-allowlists.sh, which renders the chart with
# these exact values to generate the atelet WorkloadAllowlist. Change anything
# that reaches the atelet pod (image, args, env, volumes, security context) and
# the allowlist must be regenerated, or GKE Warden rejects the DaemonSet.

rustfs:
  # Snapshot store for actors. Hyperdisk Balanced is the only disk type in GCD
  # and has a 4 GiB floor; ask for something the CSI driver will not round.
  storageSize: 10Gi
  bucketInit:
    # Exactly what Autopilot stores for the bucket Job. Its minimum CPU request
    # is 50m, so it raised the chart's 10m at creation; a Job's pod template is
    # immutable, so every later upgrade of this release (a re-run of `kagent
    # install` included) failed on the completed Job until the two matched.
    resources:
      requests: { cpu: 50m, memory: 128Mi, ephemeral-storage: 1Gi }
      limits: { cpu: 500m, memory: 256Mi, ephemeral-storage: 1Gi }

ateApi:
  authorization:
    # Principals that always hold `owner` on Substrate's global scope. `kagent
    # install` sets only kagent's controller (its Pod Certificate SPIFFE ID);
    # a values file replaces that list, so it is repeated here. The second is
    # an operator identity for `kubectl ate`: a ServiceAccount
    # (yaml/ate-operator.yaml) whose token only cluster admins can mint. The
    # shared `ate-client` fallback that `kubectl ate` uses without
    # --token-file is deliberately NOT an owner (Substrate's own advice outside
    # development). Only ate-api-server's flags change; atelet is unaffected,
    # so its allowlist stands.
    bootstrapOwners:
      - spiffe://cluster.local/ns/kagent/sa/kagent-controller
      - system:serviceaccount:ate-system:ate-operator
```

What `kagent install` adds by itself, before the values files above (from
kagent's `install.go`; a values file *replaces* a list, which is why the
controller principal is repeated in `bootstrapOwners`):

```yaml
# Substrate release
ateApi:
  authorization:
    bootstrapOwners:
      - "spiffe://cluster.local/ns/kagent/sa/kagent-controller"
credentialProvider:
  namespacePolicies:
    - atespace: "kagent"
      allowedNamespaces: ["kagent"]
# kagent release
substrateWorkerPool:
  create: true
  workerImage: "ghcr.io/kagent-dev/substrate/ateworker-gvisor:v0.6.0-alpha3"
```

The operator principal for `kubectl ate`:

[`poc/2026-10-kagent-substrate/yaml/ate-operator.yaml`](../poc/2026-10-kagent-substrate/yaml/ate-operator.yaml):

```yaml
# The operator identity for Substrate's own API (`kubectl ate`).
#
# ate-api-server authenticates a Kubernetes ServiceAccount token as
# `system:serviceaccount:<namespace>:<name>` and authorises it through OpenFGA.
# yaml/substrate-values.yaml makes this account a bootstrap owner. Its power is
# gated by Kubernetes RBAC: minting a token needs `create` on
# serviceaccounts/token in ate-system, which only cluster admins hold.
#
#   kubectl -n ate-system create token ate-operator \
#     --audience api.ate-system.svc --duration 10m > op.token
#   kubectl ate --token-file op.token get atespaces
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ate-operator
  namespace: ate-system
  labels:
    app.kubernetes.io/part-of: kagent-substrate-lab
```

Later changes to Substrate's values, without re-running the whole installer:

```bash
helm upgrade substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate --version 0.6.0-alpha3 \
  -n ate-system --reuse-values -f yaml/substrate-values.yaml --wait
```

## 2.8 Agents, sandbox template

[`poc/2026-10-kagent-substrate/yaml/agents.yaml`](../poc/2026-10-kagent-substrate/yaml/agents.yaml):

```yaml
# Agents and actors for the kagent 1.0 / Agent Substrate test.
#
# Every agent on the Berlin cluster is named trustusbank-*. In kagent 1.0 an
# Agent pairs portable behaviour (an inline template here) with a Harness, which
# says how it runs. Substrate compiles each revision into an ActorTemplate,
# boots a golden actor and snapshots it; every conversation (a Session) is then
# an actor restored from that snapshot onto a gVisor worker, and suspended to
# the snapshot store when idle.

# How these agents run: the Go ADK (kagent's own runtime; the release's pinned
# golang-adk image) on the gVisor pool, snapshots in the in-cluster RustFS
# bucket Substrate installs. The Go runtime is used rather than Python because
# a Go binary restores cleanly from a snapshot across workers.
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: trustusbank-go
  namespace: kagent
spec:
  kagent: {}
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/kagent
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: trustusbank-assistant
  namespace: kagent
spec:
  harnessRef:
    name: trustusbank-go
  template:
    inline:
      # default-model-config: OpenAI through agentgateway (yaml/kagent-values.yaml).
      modelConfig:
        name: default-model-config
      description: TrustUsBank's general assistant, running as a Substrate actor in a gVisor sandbox.
      systemPrompt: |
        You are the TrustUsBank assistant. TrustUsBank AG is a German bank, and
        you run inside its sovereign platform on Google Cloud Dedicated in
        Berlin. Answer briefly and precisely. If you do not know something, say so.
---
# The scratch environment a sandbox gets: a tools image (digest-pinned, as
# kagent requires) with kagent's guest supplied as the entrypoint. No egress:
# a sandbox with no EgressPolicy reaches nothing.
apiVersion: api.kagent.dev/v1alpha3
kind: SandboxTemplate
metadata:
  name: trustusbank-scratch
  namespace: kagent
spec:
  workload:
    image: docker.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
  env:
    - name: LANG
      value: C.UTF-8
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/sandboxes
---
# An agent that creates and drives sandboxes through kagent's own MCP API.
# Asking it to inspect its environment is the in-agent gVisor proof: the
# commands run in a separate gVisor-sandboxed actor and report gVisor's kernel.
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: trustusbank-sandbox-ops
  namespace: kagent
spec:
  harnessRef:
    name: trustusbank-go
  template:
    inline:
      modelConfig:
        name: default-model-config
      description: Runs shell commands for TrustUsBank engineers in short-lived, gVisor-isolated sandboxes.
      systemPrompt: |
        You run shell commands for TrustUsBank engineers in isolated sandboxes.
        To run a command: call create_sandbox with namespace "kagent", template
        "trustusbank-scratch" and a fresh request_id; start the command as a
        process with command ["sh", "-c", "<command>"]; poll get_sandbox_process
        until it has finished; read_sandbox_outputs; then delete_sandbox. Report
        the command output verbatim in a code block, then one sentence on what
        it shows.
      tools:
        - mcp:
            server:
              kind: RemoteMCPServer
              name: kagent-api
            tools:
              - list_sandbox_templates
              - create_sandbox
              - get_sandbox
              - start_sandbox_process
              - get_sandbox_process
              - read_sandbox_outputs
              - delete_sandbox
```

## 2.9 EgressPolicy

[`poc/2026-10-kagent-substrate/yaml/egress.yaml`](../poc/2026-10-kagent-substrate/yaml/egress.yaml):

```yaml
# EgressPolicy test (scripts/70-substrate-behaviours.sh egress).
#
# A sandbox reaches nothing unless an EgressPolicy grants it: Substrate's egress
# gateway (atenet-egress) admits only listed HTTP(S) origins, and names that no
# policy lists do not even resolve. kagent turns an EgressPolicy referenced
# from a SandboxTemplate (or an Agent) into the Substrate egress policy of each
# actor; changing the references updates running sandboxes without a restart.
#
# The template is applied WITHOUT the reference. The script proves the deny,
# then adds `egressPolicyRefs`, and proves one origin opens while another stays
# closed, in the same running sandbox.
apiVersion: api.kagent.dev/v1alpha3
kind: EgressPolicy
metadata:
  name: trustusbank-egress-example
  namespace: kagent
spec:
  destinations:
    - origin: https://example.com
---
apiVersion: api.kagent.dev/v1alpha3
kind: SandboxTemplate
metadata:
  name: trustusbank-egress
  namespace: kagent
spec:
  workload:
    image: docker.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/sandboxes
```

Granting it to a template (running sandboxes pick it up without a restart):

```bash
kubectl -n kagent patch sandboxtemplate trustusbank-egress --type merge \
  -p '{"spec":{"egressPolicyRefs":[{"name":"trustusbank-egress-example"}]}}'
```

## 2.10 Using it

```bash
export KUBECONFIG=$PWD/deploy/.kubeconfig
# Any free local port. Not 8083: it is the kagent CLI's default URL, and a local
# server or stale forward there makes the CLI talk to something else, silently.
PORT=28083
kubectl -n kagent port-forward svc/kagent-controller $PORT:8083 &
kagent() { ~/.cache/kagent/1.0.0-alpha16/kagent --api-url http://127.0.0.1:$PORT --gateway-url http://127.0.0.1:$PORT "$@"; }
SID=$(kagent agent session create --agent trustusbank-assistant -o json | jq -r .session.id)
kagent agent invoke --session "$SID" --task "Hello"
kagent sandbox create trustusbank-scratch --request-id demo-1
kagent sandbox exec <id> -- sh -c 'uname -sr; dmesg | head'

# Substrate's own view, as the operator. scripts/lib.sh (ate_cli) builds kubectl-ate from the
# v0.6.0-alpha3 tag into ~/.cache/kagent-substrate-lab/substrate-0.6.0-alpha3/; on PATH it is `kubectl ate`.
kubectl -n ate-system create token ate-operator --audience api.ate-system.svc --duration 30m > op.token
kubectl ate --token-file op.token get actors -A
kubectl ate --token-file op.token get workers

# Checkpoints and forks are MCP tools on kagent-controller (/mcp); the CLI has no command for them
scripts/kagent_mcp.py http://127.0.0.1:$PORT call create_session_checkpoint \
  '{"session_id":"<sid>","expected_head_task_id":"<task id>"}'
scripts/kagent_mcp.py http://127.0.0.1:$PORT call fork_session '{"checkpoint_id":"<checkpoint id>"}'
```
