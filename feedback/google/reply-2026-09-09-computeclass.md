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

## Consequence: A3/H100 is catalogued but not schedulable

This is why it matters to us. The accelerator hardware is in the catalogue:

```
$ gcloud compute accelerator-types list --filter='zone~u-germany-northeast1'
NAME              ZONE
nvidia-h100-80gb  u-germany-northeast1-a
nvidia-h100-80gb  u-germany-northeast1-b
```

A pod requesting one in the form Autopilot expects is admitted and then stays
`Pending` indefinitely, re-tested on this cluster today:

```
$ kubectl get pod gpu-probe
NAME        READY   STATUS    RESTARTS   AGE
gpu-probe   0/1     Pending   0          107s

Warning  FailedScheduling   gke.io/optimize-utilization-scheduler
  0/6 nodes are available: 6 node(s) didn't match Pod's node affinity/selector.
Normal   NotTriggerScaleUp  cluster-autoscaler
  Pod didn't trigger scale-up: 6 node(s) didn't match Pod's node affinity/selector
```

Pod spec: `nodeSelector cloud.google.com/gke-accelerator=nvidia-h100-80gb`,
`limits nvidia.com/gpu: 1`, `requests cpu 1 / memory 2Gi`.

Per Google's own GCD guidance the A3 Edge type
(`a3-edgegpu-8g-nolssd`) has to be requested through a **custom ComputeClass**,
and the Accelerator built-in class does not appear to cover it here. With no
ComputeClass CRD there is no way to express that request, so there is no path to
a GPU node on this cluster at all — which is the blocker rather than the quota or
the pod spec.

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
3. **If ComputeClass is not coming to GCD,** tell us the supported way to place a
   pod on `a3-edgegpu-8g-nolssd` or any H100 node under Autopilot here, since
   Autopilot is the only mode GCD offers.

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
