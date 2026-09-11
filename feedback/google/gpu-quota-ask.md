# The ask, in one page: GPU quota for eu0:soloio-eval

**Date:** 2026-09-11
**Project:** `eu0:soloio-eval`   **Region:** `u-germany-northeast1`
**Universe:** berlin (`apis-berlin-build0.goog`)

## What we need

Enough quota for **one** `a3-edgegpu-8g-nolssd` node, so we can run Gemma 3 27B
on GPU and put Solo's agent/tool governance in front of it — the Solo half of
Google's published GCD AI reference architecture.

| Quota metric | Needed | Today |
|---|---|---|
| `NVIDIA_H100_80GB_GPUS` (region `u-germany-northeast1`) | **8** | **metric does not exist** |
| `A3_CPUS` (region `u-germany-northeast1`) | **208** | **metric does not exist** |
| `C3_CPUS` (region `u-germany-northeast1`) | **48** (from 24) | 24, and we hit the ceiling |

The first two are the blocker. The third is a convenience: the agentic platform
alone consumed all 24 C3 vCPUs, which is why we could not stand up a second
cluster to test 1.36 side by side and had to destroy the first one.

## Why it cannot be self-served

These are not limits set to zero. The metrics are **absent** from the universe,
so there is no quota row to request an increase against.

```
# CPU quota metrics that exist in this region:
A2_CPUS  C2_CPUS  C2D_CPUS  C3_CPUS  CPUS  E2_CPUS  M1_CPUS  M2_CPUS  M3_CPUS
N2_CPUS  N2A_CPUS  N2D_CPUS  T2A_CPUS  T2D_CPUS  PREEMPTIBLE_CPUS
# -> A2_CPUS is present. A3_CPUS is not.

# GPU quota metrics that exist in this region:
NVIDIA_A100_80GB_GPUS  NVIDIA_A100_GPUS  NVIDIA_K80_GPUS  NVIDIA_L4_GPUS
NVIDIA_P100_GPUS  NVIDIA_P100_VWS_GPUS  NVIDIA_P4_GPUS  NVIDIA_P4_VWS_GPUS
NVIDIA_T4_GPUS  NVIDIA_T4_VWS_GPUS  NVIDIA_V100_GPUS
# -> nothing for H100.

$ gcloud compute project-info describe --format='value(quotas)' | grep -i gpu
(no global GPU quota row either)
```

Meanwhile the only GPU and the only GPU machine type Berlin actually offers are:

```
$ gcloud compute accelerator-types list --filter='zone~u-germany-northeast1'
nvidia-h100-80gb   u-germany-northeast1-a
nvidia-h100-80gb   u-germany-northeast1-b

$ gcloud compute machine-types list --filter='zone~u-germany-northeast1 AND name~a3'
a3-edgegpu-8g-nolssd   208 vCPU   1872 GB   8 x nvidia-h100-80gb
```

So every GPU with a quota metric is one this universe does not sell, and the one
GPU it does sell has no metric. The inherited public-GCP quota list appears never
to have been reconciled with Berlin's hardware catalogue.

## What we have already proved works

This is the last step, not the first. On `1.36.0-gke.4681000` (RAPID):

- the `ComputeClass` CRD is served — your engineer's fix is confirmed
- a `ComputeClass` with a GPU priority rule applies and reports healthy
- GKE Warden admits the GPU pod
- the cluster autoscaler **attempts the A3 scale-up**:

```
Normal   TriggeredScaleUp  Pod triggered scale-up:
  [{...instanceGroups/nap-1f4zkot9-temporary-mig-xdtm6vl1-async-0 0->1 (max: 1000)}]
Warning  FailedScaleUp     Node scale up in zones u-germany-northeast1-a failed:
  GCE quota exceeded. Pod is at risk of not being scheduled.
```

The whole mechanism works end to end and stops on quota alone.

One caveat we would rather raise now than discover later: if A3 in this universe
also requires project allowlisting or has no physical capacity in `-a`/`-b`,
quota alone will not be enough. If either applies, please say so alongside the
grant so we can plan.

## Why it matters to both sides

Berlin has no `aiplatform`, so in-universe inference is self-hosted by
definition, and Google's own GCD reference architectures answer that with
open-weight Gemma on GKE using A3/H100. Without H100 quota that blueprint cannot
be run in Berlin by Google, by Solo, or by any ISV following it — which makes
this a gap in the reference architecture's own story rather than a Solo request.

With the quota we will run Gemma 3 27B on the A3 node with Solo's agentgateway
governing agent-to-model and agent-to-tool traffic, which is the joint
Google/Solo sovereign-AI story we are both trying to be able to demonstrate.
