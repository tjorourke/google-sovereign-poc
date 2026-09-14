# Reply to Alfred — project number and the quota numbers for S3NS

**Date:** 2026-09-14

---

Hi Alfred,

Project number below. One important thing before you take it to S3NS: **8 GPUs
on their own will not be enough** — the A3 CPU quota has to come with it or the
node still will not build. Detail underneath.

## Project identifiers

```
$ gcloud projects describe eu0:soloio-eval
projectId:     eu0:soloio-eval
projectNumber: 560780937444745
parent:        organization 560780939237871
```

**Project number: `560780937444745`**

Worth a second look before it is pasted anywhere: the project number and the org
number differ only in the middle digits (`...937444745` vs `...939237871`). We
have transposed them ourselves more than once.

## What to request

For project `eu0:soloio-eval` (`560780937444745`), region
`u-germany-northeast1`:

| Quota metric | Request | Status today |
|---|---|---|
| `NVIDIA_H100_80GB_GPUS` | **8** | metric does not exist |
| `A3_CPUS` | **208** | metric does not exist |
| `C3_CPUS` | **48** (up from 24) | 24, already at the ceiling |

### Why 8 GPUs is only half the ask

`a3-edgegpu-8g-nolssd` is the only GPU machine type this universe offers — there
is no `a3-highgpu-1g`, no `g2`, no `a2`, no `n1` — so the smallest unit we can
ask for is one whole node:

```
$ gcloud compute machine-types describe a3-edgegpu-8g-nolssd --zone u-germany-northeast1-a
guestCpus:    208
memoryMb:     1916928
accelerators: 8 x nvidia-h100-80gb
```

So one node is **8 H100 and 208 vCPU of A3**. If only the GPU quota is granted,
the autoscaler will fail on the CPU quota instead and we will be back here in a
week. Please make sure both land together.

### The C3 bump

Not GPU-related, but cheap to fold into the same request: `C3_CPUS` is 24 and
the agentic platform alone consumes all 24. That is why we had to destroy our
1.35.6 cluster to test 1.36 rather than run both side by side. 48 would let us
keep a working cluster while testing another, which makes us faster at answering
questions like this one.

### If round numbers are easier

208 is the exact figure for one node. If S3NS prefers round numbers, 256 for
`A3_CPUS` is comfortable and still only permits a single A3 node.

## Two things we would rather hear now than discover later

1. **Does A3 in Berlin also need project allowlisting**, separately from quota?
   That is common for scarce GPU SKUs in public GCP, and if it applies here we
   would like it done in the same pass.
2. **Is there physical A3 capacity in `u-germany-northeast1-a` or `-b`?** The
   accelerator catalogue lists `nvidia-h100-80gb` in both zones, but a catalogue
   entry is not a guarantee of stock. If capacity is the real constraint, that is
   a different conversation and better had now.

## Where this leaves us

To be clear about the sequence, since it has moved twice: your engineer's
ComputeClass finding was correct and is **resolved** — on `1.36.0-gke.4681000`
RAPID the CRD is served, our ComputeClass applies, Warden admits the pod, and the
cluster autoscaler genuinely attempts the A3 scale-up. It then stops on
`GCE quota exceeded` and nothing else. Quota is the last thing between us and
running Gemma 3 27B on GPU with Solo's governance in front of it.

Thanks for pushing this through to S3NS.

Tom
