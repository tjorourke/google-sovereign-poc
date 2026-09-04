# Istio ambient on GKE Autopilot in Google Cloud Dedicated

**Status: working.** Verified 2026-09-04 on `eu0:soloio-eval`, cluster `agentic`,
Istio 1.30.4. This document is the record of how, and of the five things that had
to be discovered to get there.

This reverses the central finding of this engagement. Finding 01 said Istio
ambient could not run on GCD, and for the first days of the evaluation that was
correct: Autopilot rejects the privileged DaemonSets ambient needs, and Berlin's
own GKE differences page states that the allowlist mechanism is unavailable.
That page is wrong, and it is still wrong today:

> **Privileged workload admission control** — Creating and installing allowlists
> to run privileged workloads in Autopilot clusters is not supported.

Privileged Admission Control has in fact shipped in GCD. Google confirmed on
2026-09-04 that it is recent and had not been customer-verified. It has now been
verified, by us.

## What is running

```
$ kubectl -n istio-system get ds
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
istio-cni-node   5         5         5       5            5
ztunnel          5         5         5       5            5

$ kubectl get workloadallowlists
NAME                   AGE
istio-cni-1.30.4       ...
istio-ztunnel-1.30.4   ...

$ kubectl -n kagent get gateway agent-waypoint
NAME             CLASS            ADDRESS       PROGRAMMED
agent-waypoint   istio-waypoint   10.36.10.51   True
```

The `kagent` and `model` namespaces are enrolled in ambient. All their workloads
were captured in place, with no pod restarts. The agent platform continues to
work: `sovereign-calc` still answers and still calls its MCP tool through
agentgateway, now over mTLS.

Enforcement is verified by `scripts/66-istio-health.sh`, ten checks, all passing:
DaemonSet health, allowlist installation, ambient capture, mTLS peer identities,
L4 identity policy, L7 method policy, and policy removal restoring traffic.

## What GCD gains from this

Three things this environment had no mechanism for at all, until now.

**Workload mTLS.** Every connection between enrolled workloads is mutually
authenticated, with SPIFFE identities derived from Kubernetes ServiceAccounts.
Taken from ztunnel's own metrics, on real platform traffic:

```
source_principal="spiffe://cluster.local/ns/kagent/sa/health-allowed"
source_principal="spiffe://cluster.local/ns/kagent/sa/kagent-controller"
destination_principal="spiffe://cluster.local/ns/kagent/sa/health-server"
destination_principal="spiffe://cluster.local/ns/kagent/sa/kagent-tools"
destination_principal="spiffe://cluster.local/ns/model/sa/default"
```

**L4 authorization on identity, not IP.** GCD has no GKE network policies and no
Cloud Service Mesh, so before this there was no way to express "only this
workload may reach the model". Two clients on the same node, adjacent pod IPs,
different ServiceAccounts, get different answers:

```
L4 ALLOW policy: health-allowed=200, health-denied=000
```

**L7 authorization.** ztunnel terminates HBONE and sees TCP, so it can allow or
deny a connection by identity but cannot read an HTTP method. The waypoint can:

```
L7 method policy: GET=200, DELETE=403
```

Note the difference in failure shape, which is worth showing a customer: an L4
deny kills the connection (curl reports `000`), an L7 deny returns a 403 with the
connection intact.

## How the allowlist mechanism works

Four moving parts, and the order matters.

1. A **`WorkloadAllowlist`** (`auto.gke.io/v1`) is the enforcement object. GKE
   Warden validates a candidate workload against every installed allowlist and
   admits it only on a match. `matchingCriteria` covers `hostNetwork`, `hostPID`,
   `hostIPC`, `volumes`, and per-container `securityContext.capabilities`,
   `privileged` and `appArmorProfile`. `exemptions` lists the Warden constraints
   being waived.

2. An **`AllowlistSynchronizer`** installs them. You cannot create a
   `WorkloadAllowlist` directly; GKE accepts them only from an authorised source.
   The synchroniser names a bucket and object paths, and the GKE service agent
   reads those files and installs them, keeping them in sync. Re-uploading to the
   same path is therefore enough to update an allowlist.

3. A **Cloud Storage bucket** holds the files. The **GKE service agent** needs
   `roles/storage.admin` on it, which is easy to miss and produces a synchroniser
   error that reads like a policy problem.

4. The **managed org policy** `container.managed.autopilotPrivilegedAdmission`
   lists the paths clusters may install from, and the cluster's
   `--autopilot-privileged-admission` value must be drawn from it. Keep
   `allowAnyGKEPath: true` or you lose the default authorisation of every GKE
   partner and approved open-source allowlist.

Our org needed no eligibility request. The policy was accepted first time. The
one failure was propagation: the cluster update was refused for about two minutes
after the policy was set, with `CUSTOM_ORG_POLICY_DENIED`, then succeeded
unchanged. If you hit that, wait rather than debug.

## The five things that had to be discovered

None of these are in Google's documentation. Together they are most of the value
in this record.

### 1. GKE generates the allowlist for you

Warden's rejection ends with a hint that is easy to miss:

> To generate an allowlist for this workload, add the
> `cloud.google.com/generate-allowlist: "true"` annotation to your Pod.

Annotate the pod template, apply with `--dry-run=server`, and GKE returns a
complete `WorkloadAllowlist` for that exact workload. No cluster change is
needed to obtain it. `scripts/62-istio-allowlists.sh` does this for both charts.

### 2. The generated allowlist omits `appArmorProfile` for the deprecated annotation

This was the expensive one, and it has a clean fix we found only afterwards.

Istio's cni chart defaults to requesting AppArmor with the deprecated annotation
`container.apparmor.security.beta.kubernetes.io/install-cni: unconfined`, which
Kubernetes translates into `securityContext.appArmorProfile.type=Unconfined`.
**GKE's generator does not emit `appArmorProfile` for that form.** The allowlist
therefore never matches, and admission fails citing the original capability and
hostPath violations, with nothing pointing at AppArmor.

That failure mode cost the most time here: the allowlist looks correct, the
rejection is identical to having no allowlist at all, and regenerating does not
help. We found it by diffing the installed allowlist against the live pod
template field by field.

**The fix is a chart value, not a patch.** `cni.useAppArmorAnnotation=false`
makes the chart use `securityContext.appArmorProfile` instead, which the
generator *does* read. Verified directly:

```
# a pod with appArmorProfile in securityContext
$ kubectl apply --dry-run=server -f probe.yaml
...
          securityContext:
            appArmorProfile:
                type: Unconfined      <-- generator emits it
            capabilities:
                add: [SYS_TIME]
```

So the whole flow needs no post-processing and no scripting. It requires
Kubernetes 1.30 or later; on 1.29 the annotation is the only option and
`appArmorProfile` has to be added to the allowlist by hand.

`ztunnel` is unaffected either way, because it sets no AppArmor profile. That
asymmetry made the problem more confusing, not less.

This is still a GKE defect worth reporting: the generator should translate the
deprecated annotation, since Istio's chart defaults to it.

### 3. The allowlist must be generated with the same Helm values used to install

Matching is exact and image-pinned. `profile=ambient` changes ztunnel's image to
`:1.30.4-distroless` and adds `ISTIO_META_ENABLE_HBONE`; both appear in
`matchingCriteria`. An allowlist generated without that flag is silently
rejected. So is one generated with a different `cni.cniBinDir`. Generation and
installation are coupled, which is why they share variables across
`62-istio-allowlists.sh` and `64-istio-ambient.sh`, and why the installer asserts
that the installed allowlist agrees with the directory it is about to use.

### 4. `cni.cniBinDir` must point at GKE's writable CNI directory

Container-Optimized OS mounts `/opt/cni/bin` read-only, so istio-cni passes
admission and then crash-loops:

```
error  cni-agent  failed file copy of /opt/cni/bin/istio-cni to /host/opt/cni/bin:
       read-only file system
warn   hint: some Kubernetes environments require customization of the CNI directory
```

Set `cni.cniBinDir=/home/kubernetes/bin`. Note that `global.platform=gke` does
**not** fix this in 1.30.4; all it adds is a ResourceQuota. This is a failure
that happens after the hard part is solved, which makes it easy to misread as an
allowlist problem.

### 5. Autopilot gates the `system-node-critical` priority class per namespace

Both DaemonSets set `priorityClassName: system-node-critical`, and they should:
they are node infrastructure and must not be evicted before application
workloads. Autopilot limits that priority class with a per-namespace
`ResourceQuota`, shipped in `kube-system` and its own `gke-managed-*` namespaces
but not elsewhere. Without one in `istio-system`:

```
Error creating: insufficient quota to match these scopes:
  [{PriorityClass In [system-node-critical system-cluster-critical]}]
```

which looks nothing like a priority class problem. `global.platform=gke` ships
`istio-cni-resource-quota` for this; we also keep our own copy at
`istio-ambient/critical-pods-quota.yaml` so the dependency is explicit rather
than an accident of a platform flag.

## AccessPolicy: the agent layer on top

With ambient running, Solo's `AccessPolicy` (`policy.kagent-enterprise.solo.io/v1alpha1`)
becomes usable, and it is the object a governance buyer actually wants. It is the authored
source of truth for "which agent may call which tool", and the kagent controller compiles it
into both enforcement layers at once.

Enable it with `controller.istioAuthzTranslation.enabled=true` on the kagent chart. It defaults
to false, which is correct for a cluster with no mesh and is why ours was off.

One authored object:

```yaml
apiVersion: policy.kagent-enterprise.solo.io/v1alpha1
kind: AccessPolicy
metadata: { name: allow-sum-only, namespace: agents }
spec:
  action: ALLOW
  from:
    subjects: [{ kind: Agent, name: waypoint-calc, namespace: agents }]
  targetRef:
    kind: MCPServer
    name: everything-server
    tools: [sum]
```

compiles into two:

```
L7, at the waypoint   (source.identity.namespace == "agents" &&
                       source.identity.serviceAccount == "waypoint-calc") &&
                      (mcp.tool.name == "sum")

L4, at the mesh       principals: [cluster.local/ns/agents/sa/waypoint-calc]
                      selector:   app.kubernetes.io/name: everything-server
```

Verified enforcing: the agent requests three tools, the policy grants one, and it can call
`sum` while `echo` never appears in its tool list at all.

**This also corrects a claim in this repo.** The `enterprise-agentgateway-waypoint`
GatewayClass was recorded as unable to work here and as failing silently. With ambient running
it provisions properly and is `PROGRAMMED`, and its logs show it is MCP-aware and
identity-aware:

```
gateway=agents/mcpserver-everything-server-waypoint
src.identity=spiffe://cluster.local/ns/agents/sa/waypoint-calc
protocol=mcp mcp.method.name=tools/list http.status=200
```

Three constraints to design around, none of them documented:

- **`AccessPolicy` tool-scoping needs a kagent `MCPServer`,** not a `RemoteMCPServer`. A
  `RemoteMCPServer` is only a URL, so there is nothing for the translator to attach to.
- **The `kagent` namespace is reserved** for policies. Agents and tool servers that are to be
  governed live elsewhere. Every Solo lab does this and none says why.
- **The generated L4 policy omits the waypoint's own identity,** which silently breaks tool
  discovery and is reported as a `401` from the tool server. Written up in
  `feedback/solo/01-accesspolicy-waypoint-hop.md`, with the one-object workaround.

The three paths now coexist, and all three are checked by
`scripts/69-accesspolicy-health.sh`: the hand-written agent and the registry-deployed agent on
the standalone gateway, and the waypoint agent under `AccessPolicy`.

## One real operational cost

**You cannot exec into or port-forward to an allowlisted pod.** GKE stamps
`autopilot.gke.io/no-connect: "true"` on every pod admitted through a
`WorkloadAllowlist`, and the `autogke-no-pod-connect-limitation` constraint then
refuses connections to it:

```
$ istioctl ztunnel-config workload
denied by autogke-no-pod-connect-limitation:
  Cannot connect to pod istio-system/ztunnel-..., with annotation
  "autopilot.gke.io/no-connect": "true".
```

This is defensible as a security property, and it is a genuine operational
constraint that Google should document alongside the feature. `istioctl
ztunnel-config` and `istioctl proxy-config` do not work against ztunnel on
Autopilot. `kubectl logs` still does, and ztunnel's metrics port is an ordinary
network endpoint, so it can be scraped from another pod. Both workarounds are
used in `66-istio-health.sh`.

Worth planning for: a customer's runbook for debugging ambient will not
transfer to Autopilot unchanged.

## Reproducing it

Infrastructure is code. The allowlist bucket and the GKE service agent grant are
in `infra/tofu/modules/storage`; a `project_number` variable builds the agent
email.

```bash
cd poc/2026-09-agentic-platform

# 1. generate the allowlists (server-side dry-run only, changes nothing)
./scripts/62-istio-allowlists.sh

# 2. upload them
gcloud storage cp istio-ambient/allowlists/istio-cni.yaml \
  gs://agentic-allowlist/istio/1.30.4/istio-cni.yaml
gcloud storage cp istio-ambient/allowlists/istio-ztunnel.yaml \
  gs://agentic-allowlist/istio/1.30.4/istio-ztunnel.yaml

# 3. authorise the paths at the org, then on the cluster (~20 min, once)
gcloud org-policies set-policy istio-ambient/orgpolicy-autopilot-privileged-admission.yaml
gcloud container clusters update agentic --location u-germany-northeast1 \
  --autopilot-privileged-admission='gke://*,gs://agentic-allowlist/istio/1.30.4/istio-cni.yaml,gs://agentic-allowlist/istio/1.30.4/istio-ztunnel.yaml'

# 4. install the synchroniser
kubectl apply -f istio-ambient/allowlistsynchronizer.yaml

# 5. install ambient and the waypoint (idempotent)
./scripts/64-istio-ambient.sh

# 6. prove it enforces something
./scripts/66-istio-health.sh
```

Allowlists must be regenerated on every Istio version bump, and after any change
to the Helm values used at install time. Regenerate, never hand-edit.

## What this does not change

- **Cloud Service Mesh is still unavailable.** Google's date is end of 2026 for
  GCD operators, with customer availability likely Q1 2027. This is
  *self-managed* Istio, not managed CSM. Keep those sentences apart with a
  customer.
- **GKE network policies are still unavailable.** Ambient's L4 authorization
  substitutes, and is stronger: identity rather than IP.
- **GPUs are still blocked**, and remain the more urgent problem. See finding 12.

## What we owe Google

Four items, all narrow and all implementable, tracked in
`feedback/google/01-autopilot-ambient-blocker.md`:

1. **Fix the differences page.** It states the opposite of what the product does,
   and it is why we treated ambient as structurally impossible for days.
2. **Fix the allowlist generator to emit `appArmorProfile`.** This is a defect,
   not a documentation gap, and the resulting failure is actively misleading.
3. **Document the two Autopilot preconditions** that have nothing to do with
   allowlists but block the same workloads: the per-namespace critical priority
   class quota, and the read-only CNI directory.
4. **Document `no-connect`** and its effect on exec and port-forward, next to the
   feature that causes it.

Evidence for all of it:
`feedback/google/evidence/berlin-istio-ambient-on-autopilot-2026-09-04.txt`.
