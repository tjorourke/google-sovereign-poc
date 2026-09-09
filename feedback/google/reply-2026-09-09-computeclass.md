# Reply to Google — ComputeClass CRD absent on GCD Berlin Autopilot

**Date:** 2026-09-09
**Re:** engineer's request for cluster version and `clusters describe`
**Evidence:** `feedback/google/evidence/berlin-computeclass-crd-absent-2026-09-09.txt`

---

Thanks — answers below, and I can confirm your read of it: the ComputeClass CRD
is **not** being served on our Autopilot cluster. Everything here is from a
cluster we rebuilt from scratch on 2026-09-06, so it is not carry-over state
from the original report.

## Cluster version and mode

```
NAME     LOCATION              STATUS   CURRENT_MASTER_VERSION  NODE_VERSION        AUTOPILOT  CHANNEL
agentic  u-germany-northeast1  RUNNING  1.35.6-gke.1049000      1.35.6-gke.1049000  True       REGULAR
```

- `autopilot.enabled: true`
- `initialClusterVersion: 1.35.6-gke.1049000` — created at this version, not upgraded into it
- `releaseChannel.channel: REGULAR`
- `1.35.6-gke.1049000` is the **channel default** for REGULAR in this location, i.e. what you get by asking for an Autopilot cluster with no version pinned

For context on what else is offered here, `gcloud container get-server-config
--location u-germany-northeast1` reports REGULAR defaulting to
`1.35.6-gke.1049000` with `1.36.0-gke.4447000` and `1.36.0-gke.3712000` also
valid, and RAPID defaulting to `1.36.0-gke.4681000`. So if this is fixed in
1.36.x we can move — just tell us which version carries the fix and we will
recreate on it.

Full `gcloud container clusters describe agentic --location
u-germany-northeast1` output is in the evidence file (only
`masterAuth.clusterCaCertificate` elided, as a long base64 blob).

## The ComputeClass CRD is not served

```
$ kubectl api-resources --api-group=cloud.google.com
NAME             SHORTNAMES   APIVERSION             NAMESPACED   KIND
backendconfigs   bc           cloud.google.com/v1    true         BackendConfig

$ kubectl get crd | grep -i computeclass
(no matches)

$ kubectl explain computeclass
the server doesn't have a resource type "computeclass"

$ kubectl get computeclasses.cloud.google.com
error: the server doesn't have a resource type "computeclasses"
```

`cloud.google.com/v1` serves **only** `BackendConfig`. `cloud.google.com/v1beta1`
is present as an API version but serves no resources at all.

Worth noting, because it shows this is specific rather than a broad absence of
GKE CRDs: other GKE-specific groups are served normally on the same cluster.

```
auto.gke.io/v1                   AllowlistedV2Workload, AllowlistedWorkload,
                                 AllowlistSynchronizer, WorkloadAllowlist
node.gke.io/v1                   GCPResourceAllowlist
nodemanagement.gke.io/v1alpha1   UpdateInfo
security.cloud.google.com/v1     GKEClusterTrustBundle, TrustConfig,
                                 WorkloadCertificateConfig
```

So Privileged Admission Control (`auto.gke.io`) is fully present and we are
using it in production in this cluster to run Istio ambient. It is specifically
ComputeClass that is missing.

## Consequence: both of the two supported GPU paths are closed

This is why it matters to us, and it is a bit worse than "custom compute classes
are unavailable". GKE Warden on this cluster states the supported mechanisms
itself. Requesting `nvidia.com/gpu` with only `compute-class: Accelerator` and no
accelerator type is rejected with:

```
[denied by autogke-gpu-limitation]
When requesting 'nvidia.com/gpu' resources, you must specify either node selector
'cloud.google.com/gke-accelerator' with accelerator type or node selector
'cloud.google.com/compute-class' with existing custom compute class which has at
least one GPU priority rule.
```

So there are exactly two ways in, and we have tested both on this cluster today.

**Path 1 — `gke-accelerator` with an accelerator type.** The hardware is in the
catalogue:

```
$ gcloud compute accelerator-types list --filter='zone~u-germany-northeast1'
NAME              ZONE
nvidia-h100-80gb  u-germany-northeast1-a
nvidia-h100-80gb  u-germany-northeast1-b
```

The pod is admitted and then stays `Pending` indefinitely. This is true both with
and without `compute-class: Accelerator` alongside it:

```
$ kubectl get pod gpu-accelclass
NAME             READY   STATUS    RESTARTS   AGE
gpu-accelclass   0/1     Pending   0          2m37s

Warning  FailedScheduling   gke.io/optimize-utilization-scheduler
  0/6 nodes are available: 6 node(s) didn't match Pod's node affinity/selector.
Normal   NotTriggerScaleUp  cluster-autoscaler
  Pod didn't trigger scale-up: 6 node(s) didn't match Pod's node affinity/selector
```

The autoscaler declines to provision a GPU node. Note this path needs **no**
ComputeClass CRD, so the missing CRD is not what is blocking it.

**Path 2 — a custom ComputeClass with a GPU priority rule.** Not expressible:
the CRD is not served, as above. Warden names this as a supported mechanism in
the same breath as rejecting the pod.

That combination is the finding. It is not only that custom compute classes are
missing — the path that does not need them does not scale up either.

## What would unblock us

Narrow and in preference order:

1. **Confirm whether ComputeClass is expected to be served on GCD Berlin
   Autopilot at `1.35.6-gke.1049000`.** If yes, this is a live defect on our
   cluster and we will give you whatever else you need to chase it. If no, we
   would like that stated, because Google's GCD reference architectures depend on
   it for A3.
2. **If it is fixed in a later version, name the version.** We will recreate the
   cluster on it — the whole stack rebuilds from one script, so this costs us
   about an hour and we are happy to do it as a test for you.
3. **Separately from the CRD, why does path 1 not scale up?** A pod with
   `gke-accelerator: nvidia-h100-80gb` needs no ComputeClass and still gets
   `NotTriggerScaleUp`. If A3 node auto-provisioning is simply not enabled for
   this project or this universe, that is useful to know and may be the actual
   root cause, with the CRD a second and independent gap.
4. **If neither path is expected to work in preview,** we would like that said
   plainly, because Google's published GCD AI reference architectures depend on
   A3/H100 under Autopilot and Autopilot is the only mode GCD offers.

We are also happy to give you the cluster name and project number directly, or
to run any specific command you want output from — this cluster is a preview
evaluation environment, so there is no production risk in testing on it.

## Why this matters for an ISV

Berlin has no `aiplatform`, so in-universe inference is self-hosted by
definition, and Google's own GCD reference architectures answer that by running
open-weight Gemma on GKE with A3/H100. We are currently serving a 3B model on
**CPU** because that is the only thing that will schedule, which is fine for a
functional demo and not fine for a customer-facing benchmark. Any ISV following
Google's published GCD AI blueprint hits this same wall on day one.
