# 03 — Preview project quotas are inherited from public GCP and do not match GCD's own machine catalogue

**Severity:** major
**Area:** GKE | billing
**Date raised:** 2026-09-03
**Status:** open

## Summary

The region quota set on a fresh GCD project appears to be copied from public Google Cloud rather
than tailored to GCD. It advertises quota for machine families and GPU models that GCD's own
documentation says are unavailable, while the one CPU family GCD *does* offer is capped at 24
vCPUs, and the one GPU model GCD offers has **no quota metric at all**. The practical effect is
that an ISV cannot size a deployment from the quota list, and cannot request the accelerator the
platform is documented to support.

## What we tried

```
$ gcloud compute regions describe u-germany-northeast1 --project eu0:soloio-eval --format=json
$ gcloud compute accelerator-types list --project eu0:soloio-eval --format='value(name,zone)'
$ gcloud compute project-info describe --project eu0:soloio-eval
```

Full output: `feedback/google/evidence/berlin-quotas-2026-09-03.txt` (113 metrics).

## What happened

**1. The one available GPU has no quota metric.** `accelerator-types list` offers
`nvidia-h100-80gb` in two zones:

```
nvidia-h100-80gb	u-germany-northeast1-a
nvidia-h100-80gb	u-germany-northeast1-b
```

There is **no `NVIDIA_H100_80GB_GPUS` metric** anywhere in the 113. What is present instead:

```
NVIDIA_A100_80GB_GPUS      limit=0
NVIDIA_A100_GPUS           limit=1
NVIDIA_K80_GPUS            limit=1
NVIDIA_L4_GPUS             limit=8
NVIDIA_P100_GPUS           limit=1
NVIDIA_P4_GPUS             limit=1
NVIDIA_T4_GPUS             limit=1
NVIDIA_V100_GPUS           limit=1
PREEMPTIBLE_NVIDIA_A100_GPUS  limit=16
```

Every one of those models is absent from `/compute/docs/tpc-differences`, which states only
`nvidia-h100-80gb` on A3 Edge and A3 High. So the metrics describe GPUs GCD does not offer, and
omit the one it does.

**2. `C3_CPUS` is capped at 24.** C3 is one of only three machine families GCD offers, and the only
general-purpose one. Meanwhile families the docs say are unavailable carry generous limits:

```
C3_CPUS      limit=24
CPUS         limit=100
E2_CPUS      limit=72
N2_CPUS      limit=100
N2D_CPUS     limit=100
C2_CPUS      limit=100
T2A_CPUS     limit=96      (Arm — docs say Arm is unavailable)
M3_CPUS      limit=0       (M3 IS documented as available)
```

**3. `PREEMPTIBLE_CPUS = 0`**, while `/compute/docs/tpc-differences` states that "Spot VMs are
available for all machine series (C3, M3, and A3) in Google Cloud Dedicated at discounts up to 60%
off the on-demand price."

**4. `COMMITTED_*` metrics are 0** for every family except L4 and T2D, while the Compute Engine,
GKE and BigQuery differences pages all state that spend-based committed use discounts are offered.

**5. `LOCAL_SSD_TOTAL_GB = 9223372036854775808`** (max int64), for a feature the docs say is not
supported at all — "Attached Local SSD (Gib): 0. Local SSD isn't supported in Google Cloud
Dedicated."

Cross-checks that *did* match the documentation exactly, for contrast:
`cloudArmorTier: CA_STANDARD`, `defaultNetworkTier: PREMIUM`, and the service agent domain
`...@developer.eu0-system.iam.gserviceaccount.com`.

## Why it matters for an ISV

**24 C3 vCPUs is below what a realistic ISV platform needs.** Our reference deployment — Keycloak,
kagent, the Solo management chart (ClickHouse plus two OTel collectors plus three UI services),
AgentRegistry, agentgateway, cert-manager, External Secrets and Prometheus/Grafana — requests
roughly 12-14 vCPUs before a single workload of the customer's own runs, and before any model. Add
CPU inference and it does not fit. Because GKE here is Autopilot-only, we cannot trade CPU for a
different machine family; C3 is what Autopilot schedules onto.

**We cannot deploy the documented AI story.** GCD has no `aiplatform`, so Google's own GCD
reference architectures (`/docs/gcd-solutions/`) self-host Gemma on A3/H100. With no H100 quota
metric, that path is closed to us, and the fallback the same docs suggest — "Consider doing CPU
inferencing if A3 High or A3 Edge is too large" — competes for the same 24 vCPUs.

**The quota list cannot be used for capacity planning.** An architect sizing a GCD deployment from
`regions describe` would conclude that N2, E2, C2 and Arm are available and that eight L4 GPUs
could be requested. All of that is wrong per GCD's own differences pages. We only caught it because
we had read those pages first.

**The remediation path is slow.** `/docs/quotas/tpc-differences` states quota increases must go
through GCD support, and the support prerequisites (a public Google Cloud organisation, an Assured
Workloads folder, an empty support project, then up to 48 business hours) are themselves a
multi-day task. So a quota that is wrong at project creation costs an ISV most of a week.

## What would unblock us

1. **Add an `NVIDIA_H100_80GB_GPUS` quota metric** with a non-zero default, since `nvidia-h100-80gb`
   is the only accelerator GCD offers and the documented reference architectures depend on it.
2. **Raise the default `C3_CPUS`** to something that fits a real platform — we would suggest at
   least 128 — or state a documented default in the onboarding material so an ISV can request an
   increase before starting rather than discovering it mid-deployment.
3. **Prune the quota set to GCD's actual catalogue.** Removing metrics for N2/E2/C2/T2A/Arm and for
   K80/P100/P4/T4/V100/A100/L4 would make `regions describe` usable for capacity planning, and
   would stop it contradicting the differences pages.
4. **Reconcile the three documented-but-zero cases** — `PREEMPTIBLE_CPUS`, the `COMMITTED_*`
   metrics, and `M3_CPUS` — with the differences pages that say Spot, CUDs and M3 are available.
   Either the quotas or the docs are wrong; we cannot tell which.
