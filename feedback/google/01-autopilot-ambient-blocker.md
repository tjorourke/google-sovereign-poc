# 01: GKE Autopilot-only prevents any service mesh with a node-level data plane

**Severity:** blocker
**Area:** GKE
**Date raised:** 2026-09-03
**Status:** RESOLVED for the blocker itself — Istio ambient is running on GCD Autopilot as of 2026-09-04. Four narrower defects remain open; see the resolution below.

## Summary

GCD offers GKE Autopilot only, with no Standard clusters and no privileged-workload allowlist
mechanism. Istio ambient mode cannot run under those constraints, and neither can any other CNI-
or node-proxy-based mesh or eBPF data plane. For Solo this removes our core connectivity product
from the GCD platform entirely, and the same constraint applies to every mesh and observability
ISV with a node agent.

## What we tried

Istio ambient requires two DaemonSets. From upstream Istio 1.31.0 chart manifests:

`manifests/charts/istio-cni/templates/daemonset.yaml`
- `hostNetwork: true`
- `runAsUser: 0`
- capabilities: `NET_ADMIN` (ipset and route table access), `NET_RAW` (iptables nat table
  mutation), **`SYS_ADMIN`** (comment in chart: "required for both ambient and repair")
- `priorityClassName: system-node-critical`

`manifests/charts/ztunnel/templates/daemonset.yaml`
- capabilities: `NET_ADMIN` ("Required for TPROXY and setsockopt"), **`SYS_ADMIN`** ("Required for
  `setns` - doing things in other netns"), `NET_RAW`
- `allowPrivilegeEscalation: true`
- `runAsUser: 0`, `runAsNonRoot: false`
- `priorityClassName: system-node-critical`

Note that since Istio 1.23 ambient uses in-pod traffic redirection, so ztunnel is *not* hostNetwork
it enters pod network namespaces via `setns`, which is precisely why it needs `SYS_ADMIN`. This
matters because it means the requirement is architectural, not an artifact of legacy design.

## What happened

Istio's own platform documentation states the constraint directly
(`istio.io/latest/docs/setup/platform-setup/gke/`):

> "Since the CNI node agent requires the SYS_ADMIN capability, it is not available on GKE
> Autopilot. Instead, use the istio-init container."

The suggested fallback does not help. `istio-init` is a sidecar-mode mechanism; the `istio-cni`
node agent is a mandatory, non-optional component of every documented ambient install path. There
is no ambient without istio-cni.

`ztunnel` independently violates Autopilot policy on capabilities, root user, privilege escalation
and `system-node-critical` priority class, so even a hypothetical CNI-less ambient would still be
blocked.

Autopilot's privileged-workload allowlist mechanism (`AllowlistSynchronizer` / `WorkloadAllowlist`)
exists, but Google's "Run privileged open source workloads on GKE Autopilot" page currently lists
only two allowlisted OSS workloads, Grafana Alloy and Grafana Beyla, with the caveat that
"Open-source software that requires elevated privileges and is not listed in this table might not
work on Autopilot." Istio, istio-cni, ztunnel and ambient are not mentioned.

Upstream issue `istio/istio#57356` ("Istio Ambient Mode in GKE Autopilot?") was closed as stale
with no maintainer response, so there is no roadmap signal in either direction.

## Why it matters for an ISV

1. **Service mesh is table stakes for the target verticals.** GCD's audience is regulated
   enterprises: public sector, FSI, health, insurance. Every one of them needs workload-level mTLS,
   L7 authorization and traffic telemetry to evidence DORA, NIS2 and internal segregation
   requirements. Autopilot-only removes the standard way of delivering that.

2. **The constraint is not Istio-specific.** It rules out Cilium as a mesh or CNI, any eBPF-based
   observability agent, and any security product with a node-level enforcement point. This is a
   category-wide gap in GCD's ISV story, not one vendor's packaging problem.

3. **It compounds with the absence of a Marketplace.** GCD has no Marketplace in its service list
   and there is no published ISV onboarding path (the Cloud Ready, Distributed Cloud program names
   only GDC air-gapped and connected). So an ISV currently has neither a technical path for a
   node-level component nor a commercial path to the customer.

4. **The alternative on the platform is Google's own managed Cloud Service Mesh**, which does
   support Autopilot because Google operates the privileged components itself, but it's sidecar
   only, ambient isn't mentioned in the managed CSM docs, and it isn't available in GCD's published
   service catalogue anyway. So today a GCD customer has no mesh option at all.

## What would unblock us

In rough order of how quickly each could plausibly happen:

1. **A `WorkloadAllowlist` for `istio-cni` and `ztunnel`**, either published as a supported OSS
   workload alongside Grafana Alloy and Beyla, or issued to Solo as a partner allowlist granting
   `SYS_ADMIN` / `NET_ADMIN` / `NET_RAW` and `system-node-critical` scoped to those two DaemonSets.
   This is the narrowest change and needs no platform work. Solo can supply exact
   image digests and the precise capability set.

2. **GKE Standard node pools in GCD**, even restricted to a subset of machine families. This
   unblocks the whole mesh and observability ISV category at once rather than one vendor.

3. **Confirmation that an allowlist path exists privately**, if one does. Nothing public documents
   one, and we would rather know it's available than design around its absence.

If none of these are viable before GA, we need to know now, because it changes what Solo can
credibly offer a GCD customer and how we position the engagement internally.

## Open questions for Alfred / Arun

- Is Autopilot-only a deliberate, permanent design decision for GCD, or a preview-stage limitation?
- Does the `WorkloadAllowlist` mechanism exist in the GCD universe at all? It isn't in the published
  GCD service differences.
- Is there any GCD ISV onboarding path today, image submission, signing requirements, distribution
  given Marketplace isn't in the service list?
- Is managed Cloud Service Mesh on the GCD roadmap, and if so, sidecar or ambient?

---

## Update 2026-09-04: the allowlist mechanism is present after all

This finding previously argued that GCD had no allowlist mechanism at all, citing Berlin's GKE
differences page. That page still says so:

> **Privileged workload admission control** — Creating and installing allowlists to run privileged
> workloads in Autopilot clusters is not supported.

The cluster contradicts it:

```
$ kubectl api-resources | grep -iE 'allowlist'
allowlistedv2workloads      auto.gke.io/v1   false   AllowlistedV2Workload
allowlistedworkloads        auto.gke.io/v1   false   AllowlistedWorkload
allowlistsynchronizers      auto.gke.io/v1   false   AllowlistSynchronizer
workloadallowlists          auto.gke.io/v1   false   WorkloadAllowlist

$ kubectl auth can-i create workloadallowlists.auto.gke.io
yes
```

The CRDs were installed at cluster creation (`2026-09-03T14:19:32Z`). The GCD-configured gcloud
also carries `--autopilot-privileged-admission` on `create-auto` and `update`, documented as
accepting `gs://<bucket_name>/<allowlist_path>` for user allowlists. Google (Alfred, 2026-09-04)
confirms Privileged Admission Control shipped recently in GCD and has not been customer-verified.

`WorkloadAllowlist.spec.matchingCriteria` covers `hostNetwork`, `hostPID`, `hostIPC`, `hostUsers`,
`volumes`, pod and container `securityContext` including `capabilities.add` and `privileged`, with
`containerImageDigests` pinning each container and an `exemptions` list of Warden constraints. That
is sufficient in principle for both `istio-cni` and `ztunnel`.

### What the ask becomes

The original ask was "support `WorkloadAllowlist` in GCD Autopilot, or ship Standard clusters".
The first half is apparently done. The revised ask is narrower:

1. **Confirm whether customer-owned allowlisting is enabled for organisation
   `560780939237871`.** Google's documentation states the capability is disabled by default for
   every organisation and requires an eligibility check through Customer Care. Our org has seven
   org policies set and none is an Autopilot or privileged-workload constraint, so we cannot tell
   from outside whether we are eligible.
2. **Fix the differences page.** It states the opposite of what the product does. This is the
   reason we spent the first days of this evaluation treating Istio ambient as structurally
   impossible on GCD, and it is the kind of error that will cost every other ISV the same time.
3. **Publish, or confirm the absence of, the GCD equivalent of the privileged open source
   workloads page.** Berlin's nav links to it but the page returns "This page is not available in
   Google Cloud Dedicated." If a verified allowlist for upstream Istio already exists, we would
   use it rather than building our own.

Test plan: `docs/istio-ambient-allowlist-plan.md`. We will report results either way.

---

## Resolution 2026-09-04: ambient is running, and four narrower defects remain

Istio 1.30.4 ambient is running on GKE Autopilot in `eu0:soloio-eval`:
`istio-cni-node` 5/5, `ztunnel` 5/5, both admitted through customer-owned
`WorkloadAllowlist` objects. L4 identity policy and L7 method policy are both
verified enforcing. Full method and evidence:
`docs/istio-ambient-on-gcd-autopilot.md` and
`evidence/berlin-istio-ambient-on-autopilot-2026-09-04.txt`.

Our organisation needed no eligibility request. The managed org policy
`container.managed.autopilotPrivilegedAdmission` accepted our `gs://` paths
first time. The only transient failure was propagation: the cluster update was
refused for roughly two minutes with `CUSTOM_ORG_POLICY_DENIED`, then succeeded
unchanged.

So the original ask is answered. Four narrower items remain, and each one cost us
time that another ISV will also spend.

### 1. The GKE differences page contradicts the shipped product

`/kubernetes-engine/docs/tpc-differences` still states:

> Privileged workload admission control — Creating and installing allowlists to
> run privileged workloads in Autopilot clusters is not supported.

It is supported. This single sentence is why we spent the first days of this
evaluation treating Istio ambient as structurally impossible on GCD, and why we
wrote this finding as a blocker rather than a configuration task.

**Ask:** correct the page, and add the GCD equivalents of the privileged-workload
how-tos. Berlin's nav links to them but they return "This page is not available
in Google Cloud Dedicated."

### 2. The allowlist generator omits `appArmorProfile`

This is a defect, not a documentation gap, and its failure mode is actively
misleading.

Istio's cni chart sets the deprecated annotation
`container.apparmor.security.beta.kubernetes.io/install-cni: unconfined`, which
Kubernetes translates into `securityContext.appArmorProfile.type=Unconfined` on
the pod. The allowlist GKE generates for that workload, via its own
`cloud.google.com/generate-allowlist: "true"` mechanism, **does not include
`appArmorProfile`**. The allowlist therefore never matches, and admission fails
citing the original capability and hostPath violations:

```
Violations details: {"[denied by autogke-default-linux-capabilities]": ...,
                     "[denied by autogke-no-write-mode-hostpath]": ...}
```

Nothing in that output mentions AppArmor. The allowlist looks correct, the
rejection is identical to having installed no allowlist at all, and regenerating
does not help. We found it only by diffing the installed allowlist against the
live pod template field by field.

**Ask:** have the generator emit `securityContext.appArmorProfile` when the
workload sets an AppArmor profile, including via the deprecated annotation. As a
lesser fix, name the mismatching field in the rejection message.

### 3. Two Autopilot preconditions block the same workloads and are undocumented

Neither relates to allowlists, and both bite after the allowlist is correct.

**The `system-node-critical` priority class is gated per namespace.** Autopilot
limits it with a `ResourceQuota` present in `kube-system` and `gke-managed-*` but
nowhere else. Without one in `istio-system`, pod creation fails with:

```
Error creating: insufficient quota to match these scopes:
  [{PriorityClass In [system-node-critical system-cluster-critical]}]
```

which gives no hint that a priority class is involved.

**The CNI binary directory is read-only.** Container-Optimized OS mounts
`/opt/cni/bin` read-only, so istio-cni passes admission and then crash-loops with
`read-only file system`. `global.platform=gke` does not fix this in Istio 1.30.4;
`cni.cniBinDir` must be set to `/home/kubernetes/bin` explicitly.

**Ask:** document both on the privileged-workload pages, since anyone
allowlisting a CNI or node agent will hit them immediately after solving the
allowlist.

### 4. `no-connect` blocks exec and port-forward, and is not documented with the feature

Every pod admitted through a `WorkloadAllowlist` is stamped
`autopilot.gke.io/no-connect: "true"`, and `autogke-no-pod-connect-limitation`
then refuses connections to it:

```
$ istioctl ztunnel-config workload
denied by autogke-no-pod-connect-limitation:
  Cannot connect to pod istio-system/ztunnel-..., with annotation
  "autopilot.gke.io/no-connect": "true".
```

We think this is a reasonable security property. It is also a real operational
cost: `istioctl ztunnel-config` and `istioctl proxy-config` cannot be used
against ztunnel on Autopilot, so a customer's existing runbook for debugging
ambient does not transfer. `kubectl logs` still works, and the metrics port can
be scraped from another pod, but both are workarounds a customer has to discover.

**Ask:** state this on the privileged-workload pages, so an operator learns it
before committing to the architecture rather than during an incident.
