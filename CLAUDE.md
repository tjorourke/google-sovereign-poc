# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

# Solo.io on Google Cloud Dedicated (Germany)

Repo for Solo.io's evaluation of **Google Cloud Dedicated (GCD)** in Germany: infrastructure
bootstrap, reference architectures, POCs, and the written feedback we hand back to Google.

Owner: Tom O'Rourke, Field CTO EMEA, Solo.io.
Status: **preview environment, pre-GA.** German GCD GA is expected end of 2026.

**Commercial goal:** establish Solo as the connectivity and agentic-infrastructure layer for
sovereign Google Cloud in EMEA, starting with one vertical pain point (public sector, FSI, health
or insurance) and an ISV onboarding path that currently doesn't exist for GCD.

**Google-side contacts:** Sanjay coordinating. Arun (Dubai) leads Partner Technical Architects with
a sovereignty focus. Alfred (ET) is his ISV counterpart inside the GCD product team. Both have
onboarded strategic ISVs before, so they're the institutional knowledge. Morning PT works for both
timezones.

France's equivalent universe (S3NS / PREMI3NS, SecNumCloud 3.2) is already GA and is the best
public proxy for how Berlin will behave.

---

## Read this first: the one thing that shapes everything

**Istio ambient RUNS on GCD Autopilot as of 2026-09-04.** Do not repeat the claim
that it cannot. This section previously said the opposite and was wrong from the
moment Privileged Admission Control shipped in GCD.

`istio-cni` and `ztunnel` are admitted through customer-owned `WorkloadAllowlist`
objects, with L4 identity policy and L7 waypoint policy both verified enforcing.
Method, the five undocumented things it took, and the four defects still open with
Google: **`docs/istio-ambient-on-gcd-autopilot.md`**. Read that before touching
anything mesh-related in this repo.

What follows is the original constraint, kept because it explains the shape of
the environment and because the *default* posture is still rejection.

GCD's documented GKE offering has no Standard clusters. Istio ambient requires two privileged
DaemonSets, `istio-cni` (hostNetwork, `SYS_ADMIN`) and `ztunnel` (`SYS_ADMIN`, `NET_ADMIN`,
`runAsUser: 0`, `priorityClassName: system-node-critical`). Istio's own docs say plainly that the
CNI node agent "is not available on GKE Autopilot" because of `SYS_ADMIN`, and the suggested
fallback (`istio-init`) is sidecar-only, so it doesn't rescue ambient. Autopilot's privileged
workload allowlist currently names only Grafana Alloy and Beyla.

That's the central technical finding of this engagement and the primary feedback item for Google.
Do not write manifests, demos or customer-facing material that assume ambient runs here until it's
resolved. Track it in `feedback/google/01-autopilot-ambient-blocker.md`.

**The allowlist mechanism IS present in Berlin, despite the docs.** Berlin's GKE differences
page still says, verbatim:

> **Privileged workload admission control** — Creating and installing allowlists to run
> privileged workloads in Autopilot clusters is not supported.

> **Cloud Service Mesh** — Cloud Service Mesh is unavailable.

The second is true. **The first is not, and we have disproved it by running ambient.** The
cluster serves `auto.gke.io/v1` with `WorkloadAllowlist`, `AllowlistedWorkload`,
`AllowlistedV2Workload` and `AllowlistSynchronizer`; the GCD gcloud carries
`--autopilot-privileged-admission` accepting `gs://<bucket>/<path>`; and the managed org policy
`container.managed.autopilotPrivilegedAdmission` gates which paths a cluster may install from.
Our org needed no eligibility request.

The practical rules, all learned the hard way and all detailed in
`docs/istio-ambient-on-gcd-autopilot.md`:

- **GKE generates the allowlist for you.** Annotate the pod template with
  `cloud.google.com/generate-allowlist: "true"` and server-side dry-run it.
- **The generator omits `appArmorProfile`**, which silently breaks matching for `istio-cni` and
  produces a rejection that blames capabilities and hostPath instead. `scripts/62-istio-allowlists.sh`
  re-adds it. This is the single most expensive trap in the mechanism.
- **Generate with the same Helm values used to install.** Matching is exact and image-pinned.
- **`cni.cniBinDir=/home/kubernetes/bin`** or istio-cni crash-loops on COS's read-only `/opt/cni/bin`.
  `global.platform=gke` does not fix this in 1.30.4.
- **`istio-system` needs a `ResourceQuota`** for the `system-node-critical` priority class, or pods
  fail with `insufficient quota to match these scopes`.
- **Allowlisted pods carry `autopilot.gke.io/no-connect`**, so `kubectl exec` and port-forward into
  them are refused. `istioctl ztunnel-config` does not work on Autopilot. Use logs, or scrape
  ztunnel's metrics port from another pod.

Cloud Service Mesh remains unavailable (Google's date: end of 2026 for operators, customer
availability likely Q1 2027). What we have is **self-managed** Istio, not managed CSM. Keep those
sentences apart with a customer.

The same page states **GKE network policies are unavailable**. Combined with no Cloud NGFW
Enterprise (no TLS inspection, no IPS, no URL filtering), no load-balancer mTLS or authorization
policies, and no Certificate Manager, a GCD customer has *no* in-cluster L4/L7 policy mechanism at
all. That is a real gap for a regulated buyer and it is the gap a Solo gateway fills. Say it to
both audiences: to Google as a product gap, to the field as the wedge.

When a task in this repo touches ambient, mesh installs, or anything privileged, **surface this
constraint before answering the rest** and reference that file rather than quietly producing YAML
that will never apply. On GCD the constraint usually *is* the answer.

---

## Three distinct audiences: say which one you're writing for

Ask if it hasn't been stated.

**Google's GCD product team (Arun, Alfred).** Precise, reproducible findings that improve the
product. Exact commands, verbatim error output, and a narrow implementable ask. Not "please support
Istio" but the specific allowlist entry or capability grant that would unblock us. Frame the ISV
consequence: what does this cost Google in ISV adoption?

**Solo leadership and field (Matt and team).** The go-to-market read. Which vertical, what the pain
point is, what's blocking us technically, how long to a demo, whether this is differentiated versus
what a customer would otherwise do.

**End customers, EMEA regulated enterprises.** Exec level gets architecture and business value.
Engineer level gets CRDs, YAML, reconciliation behaviour, Envoy and ztunnel internals.

---

## Environment constants

GCD is a **separate cloud universe**, not a GCP region. Different console, different API domains,
different identity model. Nothing about `console.cloud.google.com` or `googleapis.com` applies.
If a response assumes GCP behaviour, it's wrong — flag it.

| Variable | Value |
|---|---|
| Universe name | `berlin` |
| Universe web domain | `cloud.berlin-build0.goog` |
| Universe API domain | `apis-berlin-build0.goog` |
| Universe identity domain | `id-berlin-build0.goog` |
| Universe prefix | `eu0` |
| Universe region | `u-germany-northeast1` |
| Org id | `preview-soloio` |
| Workforce pool | `preview-soloio-p` |
| Workforce provider | `preview-soloio-pp` |
| Console | `https://console.cloud.berlin-build0.goog/` |
| Docs | `https://berlin.devsitetest.how/docs` |
| Operator | Thales-owned German entity (name unannounced) |
| Org number | `560780939237871` |
| Signed-in account | `preview-soloio@id-berlin-build0.goog` (**shared**, not per-person) |
| First project | `eu0:soloio-eval` — **the `eu0:` prefix is confirmed real** |
| Project number | `560780937444745` (note: near-identical to the org number) |

These are identifiers, not secrets, which is why they're committed. Anything credential-shaped
(`wif-login-config.json`, tokens, license keys) is gitignored. See `.env.local.example`.

`berlin-build0` and `devsitetest.how` read as pre-GA staging names. **Never hardcode them.** Always
template from `.env.local`.

### Derived domains and identifiers

All confirmed from Google's Berlin doc set, 2026-09-03. Template these too.

| Thing | Value |
|---|---|
| Zones | `u-germany-northeast1-a`, `-b`, `-c` — **three**, single region, no inter-region redundancy |
| Artifact Registry domain | `pkg-berlin-build0.goog` (replaces `pkg.dev`) |
| Private Google Access VIP | `private.apis-berlin-build0.goog` → `34.3.152.0/30`, `2607:1c0:9302::/64` |
| Restricted PGA VIP | `restricted.apis-berlin-build0.goog` → `34.3.152.4/30`, `2607:1c0:9302:1::/64` |
| GKE workload identity pool | `PROJECT_ID.eu0.svc.id.goog` (**not** `svc.id.goog`) |
| User-managed service accounts | `NAME@PROJECT.eu0.iam.gserviceaccount.com` — **no `eu0:` prefix on the project here** |
| Compute default service account | `NUMBER-compute@developer.eu0-system.iam.gserviceaccount.com` |
| Service agents | `…@eu0-system.iam.gserviceaccount.com` / `…@eu0-system.system.gserviceaccount.com` |
| GKE service agent | `service-PROJECT_NUMBER@container-engine-robot.eu0-system.iam.gserviceaccount.com` |
| OS image projects | `eu0-system:debian-cloud`, `eu0-system:ubuntu-os-cloud`, `eu0-system:rocky-linux-cloud`, `eu0-system:cos-cloud` |
| gcloud CLI download | `https://storage.apis-berlin-build0.goog/cloud-sdk-release/` (in-universe copy) |
| GKE ingress firewall ranges | `34.3.144.0/23`, `34.3.151.0/26` |
| Client libraries | require `GOOGLE_CLOUD_UNIVERSE_DOMAIN` set to the API domain |

What **keeps** the public `googleapis.com` form, and must not be rewritten to `.goog`: API service
names as used by `gcloud services enable` (`bigquery.googleapis.com`), OAuth scope names, IAM
member strings, and full resource names (`//bigquery.googleapis.com/projects/…`). Only *endpoint
URLs* take the universe domain. IAM roles and permission IDs are identical to public GCP.

---

## Google's Berlin doc set: how to read it, and how much to trust it

Docs live at `https://berlin.devsitetest.how/docs`. They are **gated behind an HTTP request
header**, not a login:

```
X-DevSite-Proxy: gcd
```

In a browser, set it with the ModHeader extension. From the shell, just pass it:

```bash
curl -sL -H "X-DevSite-Proxy: gcd" https://berlin.devsitetest.how/docs/overview/tpc-key-differences
```

`scripts/gcd-docs.sh` wraps that and strips the HTML. Without the header you get the public GCP
doc corpus, silently — the same failure shape as forgetting `universe_domain`.

### The doc site is public GCP docs with GCD pages spliced in

This matters more than anything else about it. The nav, the left rail and most body pages are
inherited from `cloud.google.com` and are wrong for Berlin. Every page carries the banner *"Some or
all of the information on this page might not apply to Google Cloud Dedicated."* Take it literally.

- **`/docs/product-list` is not a GCD product list.** Its own title is "Google Cloud products at a
  glance", it was last updated 2026-04-22, and it lists Cloud TPU, Vertex AI, Spanner, App Engine,
  VMware Engine, Blockchain Node Engine, Cloud Service Mesh and Secret Manager. Ignore it entirely.
- **`/products` *is* the GCD list** ("Products and Services → Available Services").
- The doc nav's "Featured Products" strip advertises **Agent Platform, Gemini Enterprise, Apigee,
  Cloud Run, Cloud CDN, Looker**. None of those are in Berlin's live API catalogue and several are
  contradicted by GCD's own differences pages. This is almost certainly where the earlier "Gemini
  Enterprise is in GCD" impression came from. Do not quote the nav to anyone.

### The per-product `tpc-differences` pages are the declared source of truth

`/docs/overview/gcd-documentation` says so explicitly: differences pages "are updated with every
release and should be considered the 'source of truth' for feature availability." They exist for:

```
access-context-manager  armor  artifact-registry  bigquery  compute  dns  firewall (Cloud NGFW)
iam  kms  kubernetes-engine  load-balancing  logging  monitoring  nat
network-connectivity/{interconnect,router,vpn}  network-tiers  pubsub  resource-manager
service-usage  sql  storage  vpc  vpc-service-controls
```

URL shape: `https://berlin.devsitetest.how/<product>/docs/tpc-differences`. The absence of a
differences page for a product is itself a signal — there is none for Cloud Run, Secret Manager,
Cloud Service Mesh, or anything AI/ML.

**Precedence when sources disagree:** live `gcloud services list --available` on `eu0:soloio-eval`
beats a `tpc-differences` page, which beats `/products`, which beats anything else on the site.
Where a `tpc-differences` page states a hard product limit (Autopilot-only, no allowlists, no CSM)
treat it as authoritative, because it is Google stating its own constraint.

### Known-wrong pages, worth a docs finding

Small, cheap, and exactly the kind of thing Alfred's team can fix. Candidates for a single
`feedback/google/` docs finding:

- `/docs/get-started/required-domains` lists `console.cloud.google.com` and `*.googleapis.com` as
  the domains to allowlist on a corporate proxy. For Berlin those are `console.cloud.berlin-build0.goog`
  and `*.apis-berlin-build0.goog`. A customer following this page verbatim cannot reach the console.
- `/docs/quotas/tpc-differences` uses `region=europe-west9-a` in its example. That is Paris — France
  leaking into the German doc set.
- `/storage/docs/tpc-differences` says the Cloud Storage FUSE CSI driver is "not available" in GCD;
  `/kubernetes-engine/docs/tpc-differences` says it is supported from `1.36.0-gke.1266000`.
- `/docs/overview/tpc-key-differences` says CUDs are not available; the Compute Engine, GKE and
  BigQuery differences pages all say spend-based / compute-flexible CUDs *are* offered in Germany.
- `/firewall/docs/tpc-differences` lists "App Engine: Available" and "Filestore: Available".
  Neither product exists here.
- `/products` lists **Cloud Run** and **Secret Manager**; neither appears in
  `gcloud services list --available`. Ask which is wrong — it changes our architecture either way.
- `/bigquery/docs/tpc-differences` says "Terraform support is unavailable" for BigQuery, while
  Google's own GCD reference architectures deploy BigQuery with Terraform.

---

## Auth: read this before running any gcloud command

Two failure modes cost the most time here, and both look like something else:

1. **You forgot `universe_domain`.** gcloud defaults to `googleapis.com`, silently talks to public
   GCP, and you get auth errors or 403/404 on projects that don't exist. Always work inside a named
   gcloud configuration.
2. **`gcloud auth login` ends on a "Login successful" page.** That means you authenticated against
   GCP, not GCD. **A 404 in the browser is the correct outcome.**

There are no Google Accounts in GCD. Cloud Identity is unavailable. Identity comes only from an
external IdP via Workforce Identity Federation, plus service accounts.

```bash
source .env.local

gcloud config configurations create "${UNIVERSE_NAME}" 2>/dev/null || true
gcloud config configurations activate "${UNIVERSE_NAME}"
gcloud config set universe_domain "${UNIVERSE_API_DOMAIN}"

AUDIENCE="locations/global/workforcePools/${WORKFORCE_POOL}/providers/${WORKFORCE_PROVIDER}"

gcloud iam workforce-pools create-login-config "${AUDIENCE}" \
  --universe-cloud-web-domain="${UNIVERSE_WEB_DOMAIN}" \
  --universe-domain="${UNIVERSE_API_DOMAIN}" \
  --output-file="${WIF_LOGIN_CONFIG}" \
  --activate

gcloud auth login --login-config="${WIF_LOGIN_CONFIG}"

# Separate call. Terraform and client libraries need ADC and will not pick up the above.
gcloud auth application-default login --login-config="${WIF_LOGIN_CONFIG}"
```

`scripts/gcd-auth.sh` wraps this. Use it rather than retyping the commands.

IAM member strings keep the literal `iam.googleapis.com` host even inside the universe. Do **not**
rewrite them to `.goog`:

```
principal://iam.googleapis.com/locations/global/workforcePools/preview-soloio-p/subject/SUBJECT
principalSet://iam.googleapis.com/locations/global/workforcePools/preview-soloio-p/group/GROUP
```

Confirmed live 2026-09-03, the CLI account string is exactly:

```
principal://iam.googleapis.com/locations/global/workforcePools/preview-soloio-p/subject/preview-soloio@id-berlin-build0.goog
```

### gcloud ordering traps (all cost time on day one)

- `gcloud config set project` **validates the project**, so it needs an active account. Set it
  *after* `gcloud auth login`, not before.
- `gcloud config set compute/region` validates the region against the active project, so it needs
  `core/project` set *first*.
- **ADC does not inherit the quota project.** Run
  `gcloud auth application-default set-quota-project eu0:soloio-eval` or Terraform and the client
  libraries fail with "quota exceeded" / "API not enabled".
- `gcloud auth list` will show a public-GCP account (`…@solo.io`, universe `googleapis.com`)
  alongside the universe principal. One `gcloud config set account` away from silently talking to
  the wrong cloud. Always confirm `universe_domain` in `gcloud config list` before trusting output.

### The default org binding does not let you create anything

The org ships with exactly one IAM binding: the whole workforce pool granted
**Organisation Administrator**. That role deliberately excludes
`resourcemanager.projects.create`, so the first project fails until you self-grant. Org Admin
does include `organizations.setIamPolicy`, which is the authority to make that grant.

Add `roles/resourcemanager.projectCreator` (and `roles/billing.admin`) to:

```
principalSet://iam.googleapis.com/locations/global/workforcePools/preview-soloio-p/*
```

Use **Grant access** to add a binding, never the pencil icon on the existing row: that row is the
only thing granting you authority in the org, and there is no Google Account fallback if you
delete it. **Re-login after granting** — the existing token carries the old role set, and the
failure looks identical to the grant not working.

Google's onboarding note calls the role `project.creator`. **No such role ID exists.** It is
`roles/resourcemanager.projectCreator`, display name **Project Creator**. Searching the role picker
for `project.cre` returns "No matches" and looks like the role is absent from the universe. It
isn't. Filter the picker by `projectCreator`, or by the permission `resourcemanager.projects.create`.

The console truncates the *front* of principal strings (`…preview-soloio-p/*`). Use the copy icon
in the row to get the literal value; read the policy back with
`gcloud organizations get-iam-policy 560780939237871 --format=json`.

**The console lies about IAM until you re-login.** After any grant, and after creating a project,
the console will show "You need additional access" listing roles you already hold. The token is
stale, nothing is broken. Sign out and back in before believing any permission error. Confirmed
2026-09-03: a project that the console claimed was inaccessible had a correct `roles/owner`
binding all along.

The creator's automatic `roles/owner` grant **does** fire for a workforce-federated principal.
Verified on `eu0:soloio-eval`.

**Identities here are shared.** `preview-soloio@id-berlin-build0.goog` is an org-level account, not
a per-person one, so there is no individual audit attribution. Fine for our eval; not viable for a
regulated customer, and worth raising with Google as an ISV onboarding gap.

**Project IDs carry the universe prefix.** `myproject` becomes `eu0:myproject`. The colon breaks a
lot of tooling that assumes a DNS-safe project id. Expect it, and quote it everywhere.

---

## Repo layout

```
infra/bootstrap/    gcloud + WIF setup, org policy, project creation, IAM
infra/terraform/    Terraform. Provider MUST set universe_domain. Recent provider only.
infra/helm/         Values files and install wrappers for Solo components
demos/              Runnable reference architectures, one directory each, each with its own README
poc/                Time-boxed experiments. Disposable. Date-prefixed: poc/2026-09-mcp-egress/
feedback/google/    Numbered findings we hand to Google. The most valuable output in this repo.
docs/               Positioning, sovereignty framing, customer-facing material
scripts/            Shared shell helpers
```

### Rules per tree

- **`infra/`**: nothing hardcodes a hostname. Every registry, endpoint and project id comes from
  a variable. This code has to survive the staging domains being renamed at GA.
- **`demos/`**: must be reproducible from a clean project by someone who isn't Tom. Every demo
  README states its prerequisites, its exact versions, and a teardown command.
- **`poc/`**: allowed to be scrappy. Do not import from `poc/` into `demos/` or `infra/`; promote
  by rewriting.
- **`feedback/google/`**: the deliverable Google actually asked for. See format below.
- **`docs/`**: customer-facing. Sovereignty claims here must be attributable. See the compliance
  section.

---

## Feedback file format

Google's ISV team (Arun, Alfred) get institutional value from precise findings, not impressions.
Every file in `feedback/google/` is numbered and follows this shape:

```markdown
# NN — Short title

**Severity:** blocker | major | minor | question
**Area:** GKE | Artifact Registry | IAM | networking | Terraform | docs | billing
**Date raised:** YYYY-MM-DD
**Status:** open | acknowledged | workaround | resolved

## What we tried
Exact commands, exact versions.

## What happened
Verbatim output. No paraphrasing.

## Why it matters for an ISV
The commercial consequence, framed for the GCD product team.

## What would unblock us
A specific, implementable ask. Not "please support X" but the narrowest change that works.
```

Keep "what happened" verbatim. A pasted error message is worth more to Alfred's team than a
sentence describing it. `feedback/google/01-autopilot-ambient-blocker.md` is the worked example.

---

## Berlin's actual service catalogue

**Verified 2026-09-03** on `eu0:soloio-eval` via `gcloud services list --available`. Full output is
committed at `feedback/google/evidence/berlin-services-2026-09-03.txt`. Berlin preview ships
**31 services**, materially narrower than the French GA universe. Prefer this list over any
France-derived extrapolation. Re-verify before GA.

```
accesscontextmanager  apikeys  artifactregistry  autoscaling  bigquery  bigqueryreservation
bigquerystorage  cloud  cloudapis  cloudbilling  cloudkms  cloudresourcemanager  compute
container  discovery  dns  essentialcontacts  iam  iamcredentials  logging  monitoring
networkconnectivity  networksecurity  orgpolicy  pubsub  servicedirectory  serviceusage
sqladmin  storage  storage-component  sts
```

### Where the docs and the live catalogue disagree

Google's `/products` page claims **Cloud Run** and **Secret Manager** are available services in
Berlin. Neither appears in `gcloud services list --available` on `eu0:soloio-eval`, and neither has
a `tpc-differences` page. Other differences pages then contradict `/products` again: Cloud NAT,
Cloud Load Balancing and Pub/Sub all say plainly that "Cloud Run, Cloud Run functions, and
App Engine are unavailable", while Compute Engine says CUDs cover "Compute Engine, GKE, and
Cloud Run". Treat both as **absent today, possibly on the near-GA roadmap**, and ask Google which
it is — Secret Manager in particular changes how we handle license keys and TLS material.

`/products` also names services the API list groups under a parent: Access Transparency,
Access Approval (via the VPC-SC supported-services list), API Discovery Service, API Keys,
BigQuery Reservation, Service Account Credentials, Service Directory, Organization Policy, and
workforce/workload identity federation via STS. Those are consistent with the 31, not additions.

### The three absences that decide our strategy

**1. No `aiplatform` / Vertex AI / Gemini — but Google has published its own answer to that.**
There is no managed model inference in Berlin, and the doc nav's advertisement of Gemini Enterprise
and Agent Platform is inherited public-GCP furniture, not a GCD claim. What changed on 2026-09-03
is that Google's own GCD reference architectures (`/docs/gcd-solutions/`) show the intended
pattern: **self-hosted open-weight Gemma (`google/gemma-3-27b-it`) on GKE, plus BigQuery ML and
BigQuery vector search for RAG**, explicitly "without ever making external API calls or moving data
outside the sovereign boundary." A3 machines with NVIDIA H100 80GB are available
(`a3-highgpu-{1,2,4,8}g-nolssd`, `a3-edgegpu-8g-nolssd`), so the hardware is there.

So the agentic story is **not blocked** — it is *self-hosted*. That is a better sovereign story than
a managed model would have been, and it is the story Google is already telling. Build on it.

**2. No Cloud Service Mesh** (`mesh`/`anthos`/`gkehub` all absent, and the GKE differences page
states it outright). A GCD customer has no mesh option whatsoever: not Istio ambient (Autopilot
blocks the DaemonSets and GCD blocks the allowlist mechanism), not sidecar Istio via managed CSM
(the service does not exist here), not Cilium. Verified for Berlin, not inferred from France.

**3. No `secretmanager`.** Nowhere to put LLM provider API keys, Solo license keys or TLS material
except Kubernetes Secrets — and GKE on GCD additionally has no application-layer Secret encryption
("Encrypting Secrets at the application layer is not supported"). CloudKMS *is* present, so
envelope encryption into a Secret is the available pattern. Note Cloud KMS here has **no HSM
protection level at all** (neither multi-tenant nor single-tenant Cloud HSM), no EKM, no Autokey.
Software-protected CMEK is the ceiling in preview. Do not imply otherwise to a regulated buyer.

### Other confirmed absences

`cloudbuild` · `binaryauthorization` · `certificatemanager` · `privateca` · `containeranalysis`
`gkehub` / `connectgateway` (Fleet) · `run` / `cloudfunctions` (no serverless) · `spanner`
`redis` / `memorystore` · `cloudtrace` / `clouderrorreporting` · `cloudscheduler` / `cloudtasks`
`workflows` / `eventarc` · `apigee` / `apigateway` · `iap` · `cloudasset` · `servicenetworking`
`vpcaccess` · `osconfig` / `oslogin` · `cloudidentity` · Marketplace

**The console role picker is not a service catalogue.** It offers roles for Apigee, CA Service and
Backup for GKE, none of which have an enableable API here. Do not infer availability from a role
name; check `gcloud services list --available`.

### Usefully present

- **`sqladmin`** — Cloud SQL exists, so agentregistry's Postgres dependency is satisfiable
  in-universe. Worth confirming Postgres flavour and version.
- **`cloudkms`** — available. EKM remains unattributable to GCD; do not claim it.
- **`networksecurity`**, **`networkconnectivity`**, **`servicedirectory`**, **`dns`**, **`pubsub`**,
  **`storage`**, **`bigquery`** all present.
- **`artifactregistry`** present; standard-mode only, and the registry **hostname is still
  unconfirmed** — get it from `gcloud artifacts repositories describe`.

### GKE constraints (now verified for Berlin, `/kubernetes-engine/docs/tpc-differences`)

Autopilot only, no Standard. C3 and A3 machine series only. GPUs on A3 only, no TPUs, no Arm, no
Spot VMs on node pools, no compact placement. Stable and Regular channels only. VPC-native only.
**Max 32 pods per node.** Hyperdisk Balanced storage only. No Backup for GKE, Policy Controller,
Binary Authorization, Confidential Nodes, GKE security posture, or GKE control plane authority.

Berlin-specific detail the France notes did not have:

- **No privileged-workload allowlists** and **no GKE network policies** — see "Read this first".
- **GKE version line is 1.36.x** (`1.36.0-gke.1266000` and `1.36.0-gke.2684000` are cited).
- **Workload identity pool is `PROJECT_ID.eu0.svc.id.goog`.** IAM principal shape:
  `…/PROJECT_ID.eu0.svc.id.goog/subject/ns/NAMESPACE/sa/KSA`.
- **Service agents are provisioned just-in-time** on first resource creation, *not* on API enable.
  For Shared VPC you must create the agent manually and grant its default roles first.
- Only the **general-purpose** and **Accelerator** predefined compute classes. The A3 Edge type
  (`a3-edgegpu-8g-nolssd`) must be requested explicitly via a custom `ComputeClass`.
- GKE Ingress uses a **regional** external ALB (`rxlb`); the global one (`gxlb`) does not exist.
- Ingress firewall rules need `34.3.144.0/23` and `34.3.151.0/26`.
- No Connect gateway, no Fleets/GKE Hub, no Multi Cluster Ingress or MCS, no Config Connector or
  Config Controller. **Config Sync works, manual installation method only** — no fleet defaults, no
  `ConfigDelivery`, no console dashboard; scrape Prometheus locally on port 8675 instead.
- No Ray Operator. No workload metrics. **All Google Cloud Observability integrations and
  dashboards are unavailable.**
- Cloud Storage FUSE CSI driver works from `1.36.0-gke.1266000` with
  `skipCSIBucketAccessCheck: "true"`; below `1.36.0-gke.2684000` also set
  `custom-endpoint=storage.apis-berlin-build0.goog:443`.

### Observability: plan to self-host it

This is a demo-shaping constraint, from `/monitoring/docs/tpc-differences` and
`/logging/docs/tpc-differences`.

**Cloud Monitoring cannot ingest our metrics.** No custom metrics, no Prometheus metric collection,
no OpenTelemetry, no client-library metrics, no Ops Agent. No dashboards, no charts, no alerting
policies, no uptime checks, no metrics scopes. Only listing metric types/resources/values, PromQL
queries, and Prometheus-API export are available — Google's own recommendation on that page is
"use PromQL and Grafana". So Istio, ztunnel, Envoy, agentgateway and kagent metrics have no path
into Cloud Monitoring: **every demo ships its own Prometheus and Grafana.**

**Cloud Logging is nearly as narrow.** No Ops Agent, no OSS log collection, no log-based metrics,
no log alerting, no streaming or tailing, no retroactive export. Sink destinations are project,
log bucket and Pub/Sub only — **not BigQuery, not Cloud Storage**. Cloud Audit Logs, Logs Explorer,
log views and CMEK-encrypted log buckets are available.

Worth noting for the DORA/NIS2 conversation: audit logs exist, but the evidence pipeline a bank
would build on top of them (log-based metrics, alerting, BigQuery export) does not.

### Networking and TLS: the other Berlin-specific gaps

- **Public internet egress is documented.** Cloud NAT offers Public NAT ("Only NAT for traffic to
  the internet is available"), Premium Tier addresses, IPv4→IPv4 only; Private NAT is unavailable.
  The key-differences page adds "There's separate connectivity to the Internet, using peering or
  transit." Still test it from a pod — the operator may filter — but stop describing egress as
  unknown.
- **Load balancers are regional only** — all six regional flavours, no global or classic. No
  backend buckets, no serverless NEGs, no global internet NEGs.
- **No certificate lifecycle at all.** No Certificate Manager, no Google-managed certificates,
  no global self-managed certificates, no `privateca`. Only regional Compute Engine self-managed
  certs. Plus **Cloud DNS has no public zones** and no public reverse lookup, so ACME DNS-01 through
  Cloud DNS is not a path either. Certificates are BYO and manual. This is a strong, concrete ISV
  finding and it is directly adjacent to what a Solo gateway does.
- **No load-balancer mTLS or authorization policies**, no global SSL policies, no Service
  Extensions, no Cloud CDN or Media CDN.
- **Cloud NGFW: Essentials and Standard only.** No Enterprise, therefore no TLS inspection, no
  intrusion prevention, no URL filtering, no threat intelligence, no security profiles or firewall
  endpoints.
- **Cloud Armor: Standard only**, regional external ALB only, no reCAPTCHA, no Adaptive Protection,
  no bot management, no address groups. No Security Command Center.
- **VPC Service Controls is weakened**: no standalone or custom access levels, no perimeter
  bridges, and ingress/egress rules cannot reference identities, VPC networks, service methods, or
  internal-IP access levels.
- **Access Context Manager**: basic access levels only, IP subnet and geographic conditions only.
- No default VPC network on project creation — create `default` yourself (see
  `/docs/get-started-tpc/set-up-organization/minimal-setup`). Auto-mode networks have one subnet.
  No legacy networks, no policy-based routes, no private services access, Premium Tier only.
- Private Service Connect exists but without service automation, regional/global Google API
  targets, automatic DNS, or cross-region failover.

### Compute, Cloud SQL, Artifact Registry: the practical limits

**Compute Engine.** C3 (≤176 vCPU), M3 (≤128 vCPU), A3 Edge and A3 High. No AMD, no Arm, no bare
metal, no Confidential VM, no Local SSD. **Spot VMs *are* available on Compute Engine** (to ~60%
off) even though GKE node pools cannot use them — do not repeat the France-derived "no Spot" line
without saying which surface. GPUs: NVIDIA H100 80GB only. Hyperdisk Balanced only. CMEK is the
only KEK option. Debian, Ubuntu LTS, Rocky, COS; Windows/RHEL/SLES by BYOL image adaptation. No
OS Login, no VM Manager, no serial console, no IAP TCP forwarding, no bulk VM creation. Sole-tenant
nodes, on-demand reservations, snapshots and clones are available.

**Cloud SQL.** PostgreSQL and MySQL, no SQL Server. **Enterprise Plus edition only.** C3 only
(`db-perf-optimized-C-4` … `-176`). Hyperdisk Balanced / Balanced HA, no data cache. IAM database
authentication is **service-account only** — no user or group IAM auth. PSC yes, private services
access no. No Database Migration Service, no query insights. Maintenance-window instances get no
automatic updates, which is a trap: leave the window unset or apply updates manually. agentregistry's
Postgres dependency is satisfiable, on those terms.

**Artifact Registry.** Domain is `pkg-berlin-build0.goog`. **Docker, Apt and Yum formats only**,
standard mode only, no cleanup policies, no GPG keys for Apt/Yum, and **no Artifact Analysis
vulnerability scanning**. Supported push/pull clients are listed as Docker CLI, crictl, apt and yum
— **`helm` is not on that list**, which is the concrete risk to our OCI-Helm packaging plan. Test
`helm push` early; if it fails, we ship charts as files and images via Docker.

**Cloud Storage.** Single-region buckets only, location always explicit, no default location, no
Storage Transfer Service, no Storage Insights, no domain-named buckets, service-account HMAC keys
only, no regional/locational endpoints.

**BigQuery.** BQML **internal models only** (consistent with no Vertex). No column-level access
control, no data masking, no scheduled queries, no public datasets, no Analytics Hub / Data
Transfer / Dataform / Migration APIs, and CMEK needs manual provisioning. The differences page also
claims "Terraform support is unavailable", which contradicts Google's own Terraform blueprints.

**Pub/Sub.** No schemas, no Pub/Sub Lite, **no authentication for push subscriptions**, no
Dataflow / Cloud Run / Cloud Functions integrations, no resource location restrictions.

### Identity, org setup and support: three things that cost time

**Our shared account is a bootstrap ID, and that is probably fixable by us.**
`/docs/get-started-tpc/set-up-identity-provider` describes onboarding: the operator issues a
**bootstrap ID from a special GCD IdP**, you grant it `IAM Workforce Pool Admin`, you then federate
your *own* IdP (any OIDC or SAML 2.0 provider — Entra ID, Okta, AD FS, Workspace) and re-grant
Organisation Administrator to a principal from it. `preview-soloio@id-berlin-build0.goog` is that
bootstrap ID. So the "no individual audit attribution" problem is a *state we are still in*, not a
GCD limitation — federating Solo's real IdP would fix it. Confirm that before writing it up as an
ISV gap, and reframe the finding as "onboarding leaves ISVs on a shared bootstrap ID by default".

When setting up a provider you **must** map `google.posix_username`, or SSH does not work:

```
google.subject         = assertion.subject
google.posix_username  = assertion.attributes['username']
google.groups          = assertion.attributes['groups']
```

Adding a role to the bootstrap principal via the pencil icon is what the docs tell you to do and is
safe. What is dangerous is *replacing or removing* the pool-wide binding — see the IAM section above.

**Fabric FAST is the only supported landing-zone Terraform for GCD.** Two GCD-customised variants,
"starter" (flat, single-team, everything in stage 0) and "classic" (staged 0–3, hub-and-spoke,
enterprise folder tree). The "hardened" variant is *not* customised for GCD — mine it for controls,
don't run it. Console-driven org setup does not exist here. Relevant to anything we put in
`infra/terraform/`.

**Support cases are filed from public GCP, not from GCD.** During preview, support is provided by
Google and the routing prerequisites are non-obvious: a Google Workspace or Cloud Identity account,
a **public Google Cloud organisation**, an **Assured Workloads compliant folder** with control
package *Regional Controls → EU Data Boundary and Support*, and an empty GCP project inside that
folder used only for filing cases. Then send Google the GCP org ID and that project number and wait
up to 48 business hours. Quota increases go through the same channel. **We need this standing up
before we can file anything** — including the ambient finding. Worth doing this week.

Also missing from IAM: no custom or managed org-policy constraints, no principal access boundary
policies, no Privileged Access Manager, no SCIM provisioning for Workforce Identity Federation, and
**no Policy Intelligence** — no Policy Troubleshooter, Policy Analyzer, Policy Simulator or role
recommendations. That last one matters given how often the console lies about IAM here: there is no
tool to ask *why* a permission was denied.

### Still genuinely unknown

Three earlier unknowns are now answered by Google's own docs and should not be re-asked:
Berlin's Artifact Registry domain is `pkg-berlin-build0.goog`; public egress is documented via
Cloud NAT Public NAT; and there is no private Autopilot `WorkloadAllowlist` because GCD does not
support the allowlist mechanism at all.

What is still genuinely open:

- **Whether `helm push` works against Artifact Registry.** Only Docker CLI, crictl, apt and yum are
  listed as supported clients, and there is no `helm` repository format. Decides our packaging
  strategy. Cheapest test in the repo — do it first.
- **Whether egress actually reaches the internet from an Autopilot pod.** Documented ≠ enabled; the
  operator may filter. One pod and a curl.
- **Whether Cloud Run and Secret Manager are coming.** `/products` lists both; the API catalogue has
  neither. Secret Manager changes our license-key and TLS story, Cloud Run changes nothing for us
  but tells us how fast the catalogue is moving.
- **Self-hosted Gemma on Autopilot A3.** Google's blueprints assume it works; we have not run it.
  Confirm H100 quota, the Accelerator compute class, and how a3 nodes behave under Autopilot's
  32-pods-per-node cap.
- **Per-person identity.** Whether we can federate Solo's own IdP into the preview org, or whether
  the operator has pinned us to the bootstrap ID.
- CI/CD auth: no documented pattern for federating GitHub Actions or GitLab into a GCD workload
  identity pool from outside the universe.
- Whether GKE network policies are truly absent in practice, or whether the differences page means
  only the console/Dataplane-V2 management surface. Materially changes the "no policy at all"
  argument, so verify before using it with Google.

## Terraform

```hcl
provider "google" {
  universe_domain = var.universe_api_domain   # apis-berlin-build0.goog
  project         = var.project_id            # includes the eu0: prefix
  region          = var.region                # u-germany-northeast1
}
```

Use a **recent** provider version. `universe_domain` was originally wired only into the SDK code
path, not the plugin-framework path, so older providers silently talk to `googleapis.com` for
PF-migrated resources. That bug is closed upstream but pin high and verify.

`gcloud beta terraform vet` and `gcloud beta resource-config bulk-export` don't work in a GCD
universe.

---

## Solo component versions

Verified from git tags and CRD manifests, 2026-09-03. Re-verify before pinning anything
customer-facing.

| Component | Version | Notes |
|---|---|---|
| agentgateway (OSS) | **v1.5.0** (2026-08-27) | Rust data plane, Go controller. **Not Envoy.** |
| Solo Enterprise for agentgateway | **v2026.8.2** | Needs a license key |
| kgateway | **v2.4.4** (2026-08-31) | Separate product now, see below |
| kagent | **v0.9.12** stable; **v0.10.0-rc6** (2026-08-26) | 0.10.0 not yet GA |
| KMCP | **v0.3.0** | Ships the `MCPServer` CRD |
| agentregistry | **v0.4.0** (2026-08-03) | Server + Postgres. No CRDs. |
| Agent Substrate | **v0.0.0** (2026-05-19) | **Google-led project, not Solo's.** Pre-alpha. |
| Istio upstream | **1.31.0** (2026-08-31) | |
| Solo Enterprise for Istio | **1.30.x** stable | 1.31 doc set exists; do not claim GA |
| Gateway API | **v1.6.1** | Pinned in agentgateway go.mod |

### Corrections to stale examples: these break silently

**agentgateway is a Rust data plane with a Go controller. Not Envoy.** It borrows the xDS transport
but serves its own resource types.

**agentgateway is no longer a kgateway data plane.** From kgateway 2.3.0 the agentgateway control
plane moved into the agentgateway repo. They are two separate products with separate control
planes. Any material describing "kgateway as agentgateway's control plane" is out of date.

**agentgateway CRD kinds are prefixed.** `AgentgatewayBackend`, `AgentgatewayModel`,
`AgentgatewayParameters`, `AgentgatewayPolicy`, all `agentgateway.dev/v1alpha1`. The bare names
(`Backend`, `TrafficPolicy`, `GatewayParameters`) belong to **kgateway** at
`gateway.kgateway.dev/v1alpha1` and are wrong for agentgateway.

**kagent's CRD versions are mixed.** Do not blanket-write `v1alpha2`.

**`kind: Team` was removed** (2025-09-04). **`Session` was never a CRD.** **`MCPServer` moved to
KMCP** (2025-10-21) and its group is `kagent.dev/v1alpha1`, **not** `kmcp.io`, the kagent repo's
own docs are wrong about this. Trust the manifests.

**kagent's engine is Google ADK.** AutoGen is gone. LangGraph, CrewAI and OpenAI appear as
BYO-agent samples, not the engine.

**agentregistry has no CRDs.** `ar.dev/v1alpha1` resources are served over its own REST API and
stored in Postgres, applied with its CLI, not `kubectl`.

**No semantic caching in agentgateway.** `promptCaching` exists but is provider-side prompt caching,
currently AWS Bedrock only. Don't claim semantic caching to a customer.

**ztunnel does not use hostNetwork.** Since Istio 1.23 ambient uses in-pod redirection and ztunnel
enters pod netns via `setns`, which is why it needs `SYS_ADMIN`. `istio-cni` **is** hostNetwork.
Getting this right matters when arguing the Autopilot case with Google — it makes the requirement
architectural rather than an artifact of legacy design.

### Enterprise image paths: derive them, never guess them

Verified 2026-09-03 by rendering the charts (`scripts/derive-images.sh`, driven by
`infra/helm/charts.txt`). Every path we had guessed from the product name was wrong, so treat this
as the pattern rather than the list: **Enterprise product images live under
`us-docker.pkg.dev/solo-public/<product>-enterprise/`, not on `ghcr.io`**, the binary is usually
suffixed `-controller`, and the image tag often drops the `v` the chart version carries.

| Chart | Real image |
|---|---|
| `enterprise-agentgateway` v2026.8.2 | `.../enterprise-agentgateway/enterprise-agentgateway-controller:2026.8.2` — note **no `v`** on the tag |
| `kagent-enterprise` 0.4.3 | `.../kagent-enterprise/kagent-enterprise-controller:0.4.3` and `.../kagent-enterprise/kmcp-enterprise-controller:0.4.3` |
| `management` 0.4.3 | `.../solo-enterprise/solo-enterprise-{ui-frontend,ui-backend,tunnel-server}:0.4.3` plus `solo-enterprise-autoauth:v0.2.1` (**different version line**) |
| `agentregistry-enterprise` 2026.6.1 | `.../agentregistry-enterprise/server:v2026.6.1` |

The full rendered set is **29 images**, and the charts also pull in six heavyweight third-party
dependencies we had not counted: **two different ClickHouse versions** (26.1.11.9-alpine from the
management chart, 26.2.5-alpine from agentregistry), **two Postgres** (18.3-alpine, 18) and **two
OTel collectors** (0.150.1, 0.148.0). On Autopilot with Hyperdisk-only storage and 32 pods per
node, that is worth sizing for. `infra/helm/images.txt` is now generated, not hand-written — change
`charts.txt` and re-run.

Rendering these charts needs required values or `helm template` refuses: a license key for
agentgateway and kagent, `products.kagent.enabled=true` for the management chart, and three OIDC
fields for agentregistry. `charts.txt` carries render-only placeholders after a `|`.

### The two-registry credential trap

Mirroring pulls from **public GCP** (`us-docker.pkg.dev/solo-public`) and pushes to the **universe**
(`pkg-berlin-build0.goog`). Those are different identities and docker cannot hold both through the
gcloud credential helper: `~/.docker/config.json` maps `us-docker.pkg.dev` to the `gcloud` helper,
which resolves against whichever gcloud configuration is **active**. In a GCD session that is
`berlin`, whose token has no standing at `us-docker.pkg.dev`, so every *source* pull fails with

```
ERROR: (gcloud.auth.docker-helper) ... invalid_grant: Refresh token has expired
```

which reads as the Berlin login being broken when it is the public one being consulted. A
`docker login` does not help — the credential helper wins.

`scripts/mirror-images.sh` now builds an isolated `DOCKER_CONFIG` with an inline token for the
public source registry and delegates only the universe host to the gcloud helper. Worth knowing
because the same trap applies to `helm registry login`, `arctl build --push`, and anything else
that touches both registries in one session.

**Public-GCP refresh tokens outlive the universe's.** WIF tokens here expire in hours; the
`authorized_user` credential gcloud leaves at
`~/.config/gcloud/legacy_credentials/<account>/adc.json` usually still works and can be exchanged
for an access token directly against `oauth2.googleapis.com`. `derive-images.sh` and
`mirror-images.sh` both fall back to it, which is what lets chart rendering and image caching
proceed while the Berlin session is dead.

### Verified apiVersions

```
# agentgateway v1.5.0
agentgateway.dev/v1alpha1   AgentgatewayBackend | AgentgatewayModel
                            AgentgatewayParameters | AgentgatewayPolicy
  GatewayClass: agentgateway   controller: agentgateway.dev/agentgateway

# kgateway v2.4.4 — separate product
gateway.kgateway.dev/v1alpha1  Backend | BackendConfigPolicy | DirectResponse
                               GatewayExtension | GatewayParameters
                               HTTPListenerPolicy | ListenerPolicy | TrafficPolicy

# kagent v0.9.12 / v0.10.0-rc6
kagent.dev/v1alpha2   Agent | ModelConfig | AgentHarness
                      ModelProviderConfig | RemoteMCPServer | SandboxAgent
kagent.dev/v1alpha1   Memory | ToolServer
                      (Agent and ModelConfig also still SERVED at v1alpha1)

# KMCP v0.3.0
kagent.dev/v1alpha1   MCPServer

# agentregistry v0.4.0 — NOT CRDs, served over its own REST API
ar.dev/v1alpha1   Agent | MCPServer | Model | Prompt | Skill

# Agent Substrate v0.0.0 (Google-led)
ate.dev/v1alpha1   WorkerPool (Namespaced) | SandboxConfig (Cluster) | CSIDriverConfig (Cluster)

# Istio 1.31.0 ambient + agentgateway — EXPERIMENTAL
  GatewayClass: istio-agentgateway            -> istio.io/agentgateway-controller
  GatewayClass: istio-agentgateway-waypoint   -> istio.io/agentgateway-waypoint-controller
  flag: PILOT_ENABLE_AGENTGATEWAY=true (off by default, needs ambient profile)
```

### Two mutually exclusive ways to drive agentgateway

Mixing them fails silently, the resources apply, nothing happens.

| | Standalone controller | Istiod-programmed (ambient) |
|---|---|---|
| GatewayClass | `agentgateway` | `istio-agentgateway`, `istio-agentgateway-waypoint` |
| `agentgateway.dev/v1alpha1` CRDs | used | **ignored** |
| Istio APIs (`VirtualService`, `AuthorizationPolicy`, `EnvoyFilter`…) | n/a | **ignored** |

In the istiod-programmed mode Istio configures agentgateway **only** through Gateway API resources.
On GCD this mode is moot anyway while ambient is blocked, so we're on the standalone path.

---

## Install references

```bash
# agentgateway OSS
helm upgrade -i agentgateway-crds oci://ghcr.io/agentgateway/charts/agentgateway-crds \
  --version v1.5.0 -n agentgateway-system --create-namespace
helm upgrade -i agentgateway oci://ghcr.io/agentgateway/charts/agentgateway \
  --version v1.5.0 -n agentgateway-system

# Solo Enterprise for agentgateway
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n agentgateway-system --version v2026.8.2
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n agentgateway-system --version v2026.8.2 \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"

# kagent (installs KMCP CRDs by default; substrate is opt-in, default off)
helm upgrade -i kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds -n kagent --create-namespace
helm upgrade -i kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent -n kagent

# agentregistry
helm upgrade -i agentregistry oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry \
  --version 0.4.0 -n agentregistry --create-namespace

# Solo Istio images
export HUB=us-docker.pkg.dev/soloio-img/istio
export TAG=1.30.0-solo          # or -solo-fips, -solo-distroless, -solo-fips-distroless
```

**Every one of those pulls from a registry GCD cannot reach.** With no remote or virtual Artifact
Registry repos there's no pull-through mirror, so before any install we mirror images explicitly.
Maintain the image manifest in `infra/helm/images.txt` and mirror with `scripts/mirror-images.sh`.
Template every image reference in every values file. Never hardcode `ghcr.io`, `pkg.dev` or
`us-docker.pkg.dev` into anything that runs in-universe.

FIPS builds exist and are Go BoringCrypto-based (`X:boringcrypto` in the binary build info),
relevant for regulated German customers.

---

## The agentic story, framed for sovereign

Always tie back to the three planes and name what composes: **kagent** (control, agents as
first-class Kubernetes workloads), **agentgateway** (data, MCP/A2A proxy, LLM traffic management,
tool-level authz), **agentregistry** (catalog, governance plane for MCP servers, tools, agents,
skills, with MCP Registry v0.1 read compatibility). Competitors sell pieces. Solo sells the stack.

Sovereign changes the emphasis in ways worth saying out loud:

- **In-universe inference means self-hosted, and Google has already said so.** There is no
  `aiplatform`; Gemini Enterprise and Agent Platform are not in Berlin's catalogue (verified
  2026-09-03). Google's own GCD reference architectures answer this by self-hosting open-weight
  **Gemma 3 27B IT** on GKE with BigQuery ML and BigQuery vector search for RAG, on A3/H100
  hardware, "without ever making external API calls". Egress to OpenAI or Anthropic appears to be
  *possible* (Cloud NAT Public NAT is documented) but it is the wrong story for this buyer anyway.
  Build the demo on a self-hosted model behind agentgateway; that is both the sovereign answer and
  the one Google is already telling.
- **Google has picked our two verticals for us.** `/docs/gcd-solutions/` ships exactly two GCD
  reference architectures, with Terraform implementations at
  `github.com/GoogleCloudPlatform/google-cloud-dedicated-demos`: **tax anomaly detection** for
  national tax authorities (`demos/tax-office`) and **health insurance risk analysis** for national
  healthcare agencies and regulated insurers (`demos/insurance`). Both land inside our candidate
  list (public sector, health, insurance). Both are BigQuery ML + Gemma RAG + GKE + Cloud SQL +
  JupyterHub + a web app calling the model **directly, with no gateway in the path**: no LLM traffic
  management, no per-tool authorization, no audit of agent-to-model or agent-to-tool flows, no
  catalogue. Google itself labels them unaudited proof-of-concept prototypes. That is the cleanest
  possible wedge — take Google's own blueprint, put agentgateway in front of Gemma, kagent around
  the agent, agentregistry over the tools, and the demo becomes the production-ready version of a
  reference architecture Google is already showing customers. Start with the vertical, not the mesh.
- **Tool governance is the sovereignty argument.** An agent calling an MCP server is a data flow
  that a DORA- or NIS2-obligated institution has to evidence. agentregistry as catalogue plus
  agentgateway's per-tool authz and JSON-RPC-level policy is a real audit story, and nobody else has
  the catalogue half.
- **Agent Substrate is Google's project, not Solo's.** Google-led,
  `github.com/agent-substrate/substrate`, explicitly not an officially supported Google product,
  single `v0.0.0` tag. Solo integrates with it, it's an opt-in Helm dependency of kagent, default
  off, pairing with kagent's `SandboxAgent` CRD. Never present it as a Solo product. It is, though,
  a strong joint-engineering story with Google, which is worth something in this specific
  relationship.

---

## Sovereignty and compliance: what we can and cannot claim

`docs/` is customer-facing. Sovereignty claims are exactly where a CTO audience catches overreach,
so every claim needs a source.

**Attributable:**

- GCD creates a standalone universe, physically and logically isolated from Google's public cloud,
  operated by an independent third party.
- Germany's operator is a legally and operationally independent entity wholly owned by Thales,
  staffed and managed by local German personnel. GA expected end of 2026.
- The partner holds exclusive control of identity, authentication and cryptographic roots of trust,
  and compiles the control plane from source.
- A Boundary Proxy is the only channel between Google and the universe; the partner reviews and
  approves every payload in and out, and can block updates.
- Google employees have no direct access and cannot affect service availability.
- **SecNumCloud 3.2**: achieved by S3NS in France. Validated by ANSSI.
- **C5** and **C3A**: stated *targets* for the German offering. Not achieved.

**Do not claim:**

- **DORA, NIS2, ENS, or GDPR-specific certification for GCD.** No source ties these to GCD.
  You can discuss how GCD's architecture *helps* a customer's own DORA or NIS2 obligations, but
  that's a different sentence from GCD being certified. Keep those sentences apart.
- **EU Cloud Code of Conduct.** Google holds Level 2, but that covers Google Cloud and Workspace.
  The adherence page doesn't list Dedicated at all.
- **Cloud EKM.** Cloud KMS is available; EKM is not attributable to GCD, and Berlin's own KMS
  differences page states the `EXTERNAL` protection level is not supported. The "external key
  storage" language belongs to Data Boundary, a different product.
- **HSM-backed keys.** Berlin supports neither multi-tenant Cloud HSM nor single-tenant Cloud HSM,
  and therefore not Cloud KMS Autokey. Software-protected CMEK is the ceiling in preview. If a
  customer's control framework requires an HSM protection level, say so plainly.
- **Google-operated SLAs or support.** All SLAs are with the universe's operator; Google Cloud SLAs
  do not apply. Billing is by the operator, not Google. GCD runs its own SRE team on monitoring and
  alerting stacks separate from Google Cloud. Also note the naming convention: what public GCP calls
  "Google-managed encryption keys" is renamed here to "Google Cloud-powered encryption keys /
  Managed in Google Cloud Dedicated in Germany" — "Google-powered", never "Google-managed". Use
  their wording; it is a sovereignty point in itself.

**Don't confuse the three tiers.** Google Cloud Data Boundary is residency controls inside normal
GCP. GCD is a separate partner-operated universe. Google Distributed Cloud is on-prem hardware
(connected and air-gapped modes). T-Systems Sovereign Cloud is an *overlay inside GCP*, not a GCD
instance, normal Google Accounts, normal endpoints, org-policy-enforced. S3NS **is** GCD. Mixing
these up in front of a customer is the fastest way to lose the room.

---

## Working conventions

- **Search before asserting.** Berlin is a preview universe, everything is dated, and Solo ships
  weekly. If a claim involves a version, a CRD field, a service availability or a compliance
  framework, check it and cite it. State plainly when you can't verify something rather than filling
  the gap.
- **Never invent a CRD field or an apiVersion.** A wrong field in this repo becomes a wrong slide in
  front of a bank.
- **Distinguish France from Germany.** Most public GCD detail is the French GA universe. Berlin is
  preview and probably narrower. Label which one a fact came from, and say when you're extrapolating.
- **Distinguish upstream from Solo.** Same for OSS agentgateway versus Solo Enterprise.
- Test on the smallest thing that answers the question. POCs are disposable and date-prefixed.
- Verbatim output in feedback files. Always.

## Output shape

- **Lead with the constraint** if one applies. On GCD the constraint usually *is* the answer.
- Show real YAML, Go, HCL or CLI with correct apiVersions. **Never pseudocode.**
- **Customer Value** line on anything with a customer angle: the problem, a quantifiable benefit,
  the differentiator versus what they'd otherwise run.
- **Worth noting** line for the next objection, the scaling limit, the FIPS nuance, the migration
  risk, the licensing trap, the thing Alfred will ask.
- When comparing Solo to an alternative, give the honest side-by-side and say where the competitor
  is genuinely stronger. This audience trusts technical honesty over positioning.
- For anything destined for `feedback/google/`, use the numbered finding format above and keep error
  output verbatim.

---

## AgentRegistry on GCD: how the push to kagent actually works

Verified working in Berlin 2026-09-03. This is the governance flow, and the mechanics are not
obvious from the kind labs, which solve a different problem.

**AgentRegistry is the deployer, not just a catalogue.** An `ar.dev/v1alpha1 Deployment` with a
`targetRef` to a catalogued `Agent` and a `runtimeRef` to a registered `Runtime` makes the registry
create the **kagent CRs** itself. kagent's controller then produces the workload. Nobody runs
kubectl.

```yaml
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata: { name: sovereignagent-kagent }
spec:
  targetRef:  { kind: Agent,   name: sovereignagent }
  runtimeRef: { kind: Runtime, name: kubernetes-default }
  env:                       # deploy-time config, never baked into the image
    OPENAI_BASE_URL: http://llm.agentic.eu0.internal/v1
```

**Use the seeded `kubernetes-default` runtime.** The registry seeds three runtimes (`local`,
`virtual-default`, `kubernetes-default`). `kubernetes-default` has `spec.type: Kubernetes` and **no
`spec.config.kubeconfig`**, so it acts through the registry's own ServiceAccount. The kind labs put
a kubeconfig in there because the registry had to cross a Docker network; in-cluster on GCD that is
wrong and unnecessary. The SA can create `agents.kagent.dev` and `remotemcpservers.kagent.dev` and
**cannot** create `deployments.apps`, which is the correct split.

**Objects land in the registry's namespace, not `kagent`,** when the runtime has no
`config.namespace`, and the registry derives the names (`<agent>-<tag>-<deployment>-k`). Never
assume a name: discover by label or `grep`. The kagent controller still reconciles them, and the
Enterprise UI still lists them.

**`MCP_SERVERS_CONFIG` is derived by the registry** from the MCP refs on the agent record, and it
overrides an explicit value in the Deployment `env`. Set it anyway for readability, but expect the
derived name (`sovereign-tools-sovereignagent-kagent`) to win.

**Catalogue the tool server as `spec.remote`, pointed at agentgateway**, not at the tool server's
Service. That one choice is what makes the catalogue govern by construction, and it is the sentence
to say to a customer:

```yaml
spec:
  remote: { type: http, url: http://mcp.agentic.eu0.internal/mcp }
```

`spec.source.package.origin` (OCI) is the other form and is what the kind labs use, since they run
the tool server as its own workload.

**Agent names are lowercase alphanumeric only.** No hyphens, underscores or dots, minimum two
characters. `arctl init agent sovereign-agent` fails.

**The AR `Agent` record requires a real image.** There is no declarative form as there is in kagent,
so the flow always includes `arctl build`. On GCD that means `--platform linux/amd64` (no Arm
compute) and a token-based `docker login` rather than the gcloud credential helper (finding 05).

### Reaching `arctl` from a laptop: two GCD problems

1. **No public DNS zone**, so the registry and the issuer are unresolvable and unroutable from
   outside. `kubectl port-forward` is the portable answer and needs no `/etc/hosts` edit. A second
   external `Service` selecting the existing gateway pods also works and leaves the Gateway's own
   internal Service untouched.
2. **No TLS, so a laptop cannot mint a token.** GCD has neither `certificatemanager` nor
   `privateca`, so Keycloak is plaintext HTTP. POSTing a password to it from a corporate laptop gets
   intercepted by endpoint protection as credential phishing, and you get an HTML block page where
   a JSON token should be. **Mint the token inside the cluster** (`kubectl exec` into any pod with
   python3) and export it as `ARCTL_API_TOKEN`. Mint against the *hostname* issuer, not the
   in-cluster Service DNS, or the `iss` claim will not match what the registry validates.

`poc/2026-09-agentic-platform/scripts/55-arctl-connect.sh` does both. **Source it, never pipe it** —
`source script | tail` runs it in a subshell and silently loses the exports, and the next `arctl`
call returns `401 Unauthorized`.

### A script that gets sourced must not modify the caller's shell

`lib.sh` opens with `set -uo pipefail` and its `die()` calls `exit`. Both are right for a script
that is *executed* and both are wrong for one that is *sourced*, which bit us twice:

- `set -u` survives into the interactive shell, so the next prompt that touches an unset variable
  fails with `BASHPID: unbound variable` / `TMUX: unbound variable`. It reads as a broken shell,
  and it is purely cosmetic.
- `die()` terminates the **user's shell**, not the script. Mid-demo that is unrecoverable.

So any sourced helper in this repo runs its body in a function that `return`s instead of exiting,
and saves and restores the caller's options around it:

```bash
_ARCTL_OLD_OPTS="$(set +o)"
_arctl_connect "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ARCTL_RC=$?
eval "$_ARCTL_OLD_OPTS"
```

Callers that *execute* rather than source (`56-ar-push-agent.sh`) then check `$_ARCTL_RC` instead
of relying on `set -e` semantics that no longer apply.

---

## GPU in Berlin: catalogued, not schedulable

`nvidia-h100-80gb` and `a3-edgegpu-8g-nolssd` are catalogued in zones `-a` and `-b`. A pod
requesting one in the exact form GKE Warden demands is admitted and stays `Pending` for ever with
`NotTriggerScaleUp: didn't match Pod's node affinity/selector`. There is no
`NVIDIA_H100_80GB_GPUS` metric and no `A3_CPUS` metric, so a quota increase cannot be requested.

Google's position as of 2026-09-03 is that "GPUs should be available in the environment". They are
not. Do not soften finding 12 on that basis; the evidence is in
`feedback/google/evidence/berlin-gpu-scheduling-variants-2026-09-03.txt`. The open question that
decides everything is whether GPUs require a **Standard** cluster, because GCD's documented GKE
offering is Autopilot-only, and if Standard exists here then Istio ambient does too.

**Google's dated answers, 2026-09-03:** Cloud Service Mesh is on the roadmap for **end of 2026 for
GCD operators, customer availability likely Q1 2027**. There is no native identity service and
customers must bring their own IdP with workforce/workload identity federation. Both confirm
findings 1 and 2 rather than resolving them, and the mesh date means a GCD customer has no mesh,
no workload mTLS and no network policy for the whole of preview and the first year of GA.

---

## Autopilot resource traps that cost real time

- **`ephemeral-storage` limits cause silent eviction, and `restarts` stays 0** because eviction
  recreates the pod rather than restarting the container. A chart shipping
  `ephemeral-storage: 50Mi` (Solo's management chart, for ClickHouse) makes anything that writes to
  local disk flap invisibly. Autopilot defaults to 1Gi and caps at **10Gi**.
- **A StatefulSet's `volumeClaimTemplates` cannot be changed by `helm upgrade`.** You get
  `Forbidden: updates to statefulset spec for fields other than 'replicas'…`. Delete the
  StatefulSet with `--cascade=foreground` first.
- **A PVC with an empty `STORAGECLASS` column never binds.** It means the chart set
  `storageClassName: ""`, which is "do not provision", not "use the default". It sits `Pending`
  with `pod has unbound immediate PersistentVolumeClaims` and no clue as to why.
- `hyperdisk-balanced` is the only disk type and has a **4 GB minimum**. 2Gi fails, 4Gi binds.
