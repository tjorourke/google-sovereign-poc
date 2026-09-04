# 06 — H100 is catalogued in Berlin but no GPU node will ever provision

**Severity:** blocker
**Area:** GKE
**Date raised:** 2026-09-03
**Status:** open — Google states GPUs "should be available"; they are not schedulable

## Summary

`nvidia-h100-80gb` and `a3-edgegpu-8g-nolssd` are both catalogued in
`u-germany-northeast1`. A pod requesting an H100 in exactly the form GKE Warden
demands is admitted and then stays `Pending` indefinitely. The cluster autoscaler
reports `NotTriggerScaleUp` with a node-affinity message, so it never attempts to
provision, and nothing in the output attributes the failure to quota or capacity.

There is also no quota metric for the accelerator or the machine family, so we
cannot raise a quota increase for it even if quota were the cause.

## What we tried

Project `eu0:soloio-eval` (project number `560780937444745`), cluster `agentic`,
GKE Autopilot, `u-germany-northeast1`, regular channel.

Four variants. Two are rejected at admission, which is useful because it tells us
what form is expected:

```
[denied by autogke-gpu-limitation]:
  When requesting 'nvidia.com/gpu' resources, you must specify either node selector
  'cloud.google.com/gke-accelerator' with accelerator type or node selector
  'cloud.google.com/compute-class' with existing custom compute class which has at
  least one GPU priority rule.

[denied by autopilot-machine-family-selection-limitation]:
  Pods with node selector or affinity for "cloud.google.com/machine-family" must also
  specify compute class "Performance".
```

The two remaining variants use precisely that form:

```yaml
nodeSelector:
  cloud.google.com/compute-class: Accelerator
  cloud.google.com/gke-accelerator: nvidia-h100-80gb
resources:
  limits:
    nvidia.com/gpu: 8      # variant 1, a full a3-edgegpu-8g-nolssd node
    # nvidia.com/gpu: 1    # variant 2
```

## What happened

Both are admitted, then never scheduled:

```
Warning  FailedScheduling    gke.io/optimize-utilization-scheduler
  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector.
  no new claims to deallocate, preemption: 0/3 nodes are available:
  3 Preemption is not helpful for scheduling.

Normal   NotTriggerScaleUp   cluster-autoscaler
  Pod didn't trigger scale-up: 6 node(s) didn't match Pod's node affinity/selector
```

The accelerator is catalogued, but only in two of the three zones:

```
$ gcloud compute accelerator-types list
NAME              ZONE
nvidia-h100-80gb  u-germany-northeast1-a
nvidia-h100-80gb  u-germany-northeast1-b
```

And neither the GPU nor the machine family has a quota metric:

```
NVIDIA_H100_80GB_GPUS present : False
A3_CPUS present               : False
any metric containing H100    : NONE
any metric containing A3      : NONE
```

Full transcript: `evidence/berlin-gpu-scheduling-variants-2026-09-03.txt` and
`evidence/berlin-gpu-unavailable-2026-09-03.txt`.

## Why it matters for an ISV

Google's own published reference architectures for this cloud depend on
self-hosting an open-weight model on exactly this A3 hardware, because the
universe has no `aiplatform` and therefore no managed inference of any kind. With
no GPU, the only sovereign inference path is general-purpose CPU. We have that
working, and it is enough to prove an architecture but not enough to put in front
of a regulated buyer.

So the AI story the platform is positioned on cannot currently be demonstrated by
Solo *or* by Google in this universe. That is the whole reason an ISV is here.

The silent failure mode compounds it. Because the autoscaler reports a node
affinity mismatch rather than a quota or capacity error, a vendor evaluating GCD
will conclude they have written the manifest wrong and spend a day on it. We did.

## Two further findings from the 2026-09-04 support capture

**The admission controller directs us to an API that is not served.** The
`autogke-gpu-limitation` message offers a custom `ComputeClass` with a GPU
priority rule as the alternative to `gke-accelerator`. That API does not exist
in this cluster:

```
$ kubectl explain computeclass
the server doesn't have a resource type "computeclass"

$ kubectl get crd | grep -i computeclass
  (no ComputeClass CRD installed)
```

`cloud.google.com/v1` is served but exposes only `BackendConfig`. So of the two
routes the admission message offers, one does not provision and the other does
not exist. Evidence: `evidence/berlin-computeclass-api-absent-2026-09-04.txt`.

**The quota set is inherited from public GCP, and the contradiction is exact.**
Project level has no metric containing `GPU` at all. Region level has metrics for
eight accelerator models GCD does not offer (A100, A100 80GB, K80, L4, P100, P4,
T4, V100) and none for the H100 it does. The same pattern holds for CPU
families: quota exists for A2, C2, C2D, E2, N2, N2A, N2D, T2A and T2D, while
`C3_CPUS` — the only family GCD offers and the one our nodes run — is capped at
24 with 20 in use. Evidence:
`evidence/berlin-gpu-quota-project-vs-region-2026-09-04.txt`. This sharpens
finding 03 from "quotas look inherited" to a demonstrated mismatch.

## What would unblock us

Four specific things, in order:

1. Confirm whether A3/H100 capacity is actually allocated to project
   `eu0:soloio-eval` in `u-germany-northeast1`, and in which zones. The
   accelerator is catalogued in `-a` and `-b` only.
2. Confirm whether the Autopilot `Accelerator` compute class is enabled for this
   universe. The autoscaler behaves as though no GPU node shape exists for it to
   consider, which is what we would expect if the compute class is catalogued but
   has no backing node configuration.
3. Publish the quota metric name we should be requesting. Without an
   `NVIDIA_H100_80GB_GPUS` or `A3_CPUS` metric we cannot file a quota increase,
   which also means item 5 of our support thread has nowhere to go.
4. State explicitly whether GPUs on GCD require a **Standard** cluster. GCD's
   documented GKE offering is Autopilot-only. If GPU access needs Standard, that
   is a documentation gap with large consequences, and it would also change the
   answer to finding 01, since Standard would make Istio ambient possible.

Item 4 is the one we most need answered, because it decides whether this is a
capacity allocation problem or an architectural one.
