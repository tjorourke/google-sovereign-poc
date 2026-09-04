# Agentic platform on Google Cloud — execution plan

**Goal:** a **customer reference template** for the Solo agentic stack on Google Cloud Dedicated,
not a minimal lab. Port of `solo-demos/agentic-enterprise-platform-kind`
(<https://mastertheagent.com/solo/agentic-enterprise-platform-kind/>) onto real GKE, provisioned
with OpenTofu, ending in a working MCP server + agent with tool-level authorization enforced at
agentgateway — and deliberately consuming **as much of Berlin's service catalogue as it can**.

**Why maximum coverage is the point.** This is a new relationship with Google, and the most useful
thing we can hand Arun and Alfred is not "the smallest thing that worked" but "we exercised your
universe properly, here is what carried the weight and here is what is missing". Every GCD service
we wire in is a service we can speak about with authority, and every one we try and fail on is a
finding. Cost is not the constraint; credibility is. So: real load balancers, real Cloud Armor,
real CMEK, real audit sinks, real private DNS, real Cloud SQL — the shape a regulated German
customer would actually deploy, not port-forwards.

**Date:** 2026-09-03. **Owner:** Tom.

**Status: code complete and pre-staged; nothing deployed.** Phase 1 and Phase 2 are
both written — 14 OpenTofu modules (`tofu validate` clean, google provider 8.1.0)
and 18 scripts (syntax-clean, 23 embedded manifests parsed, 9 pod specs passing a
static Autopilot admission check).

Done offline, no GCD credentials needed:

- **Image list derived by rendering the charts, not guessed.** 29 images. Every
  Solo path we had hand-written was wrong — see the CLAUDE.md section on
  Enterprise image paths. All 29 are now **pulled and cached locally**, so the
  mirror step is push-only.
- **Probe 0.8 answered and written up** as `feedback/google/02`: docker rejects
  the `eu0:` prefix inside an image reference. `.env.local` was building
  `AR_PREFIX` that way and would have failed on the first push.
- **The two-registry credential trap found and fixed** in `mirror-images.sh`.

**Blocked on:** `./scripts/gcd-auth.sh`. WIF is the only identity path in GCD, its
refresh tokens are short-lived, there is no service account key, and the browser
flow needs a human to paste a verification code. Zero cloud resources exist.

See `README.md` for the run order.

---

## Decisions taken (2026-09-03)

| Question | Decision |
|---|---|
| Target cluster | **GCD Berlin, GKE Autopilot only.** No mesh, at all. Track A (GKE Standard + ambient) is deferred, not cancelled — see below. |
| Ingress / OIDC issuer | **Real load balancers.** Regional external ALB + Cloud Armor + a self-managed regional TLS cert in front, Cloud DNS **private** zone behind, so the issuer hostname resolves natively in-cluster and no `hostAlias` bridge is needed. `*.localtest.me` + `port-forward` is kept as the documented fallback if probe 0.7 says external ingress into the universe is blocked. |
| Model | **Self-hosted in-universe.** A3/H100 Gemma is the target; **CPU inference on C3 is the fallback for today** because GPU quota is very likely not granted on a preview project. |
| IaC location | **`infra/tofu/` now**, with `gcp-standard` and `gcd-autopilot` profile modules. Every hostname, registry and project id templated — `infra/` has to survive the staging domains being renamed at GA. |
| Scope | **Maximum service coverage.** Deploy agentgateway, kagent, agentregistry, KMCP. Solo Enterprise for Istio is out — no route exists. Use every GCD service that has a defensible role in the architecture. |

### Ingress: real load balancers, with a documented fallback

You asked for LBs, and for a customer template that is the right call — a port-forward proves
nothing to a bank. Berlin has **regional load balancers only** (no global, no classic), but it has
all six regional flavours, so the customer-shaped two-tier design is available:

**Tier 1 — Google's edge.** A regional external Application Load Balancer with a static Premium
Tier external IP, a **Cloud Armor Standard** security policy attached, and a **self-managed
regional TLS certificate**. Backend is a zonal NEG pointing at the agentgateway proxy Service. This
is the tier that gives us WAF-ish rules, DDoS baseline, and TLS termination at Google's edge.

**Tier 2 — Solo's data plane.** agentgateway behind it, doing what Google's edge cannot: JWT
validation, MCP tool-level authorization, LLM traffic management, rate limits, budgets, and the
audit trail. This split *is* the wedge argument, drawn as an architecture rather than asserted on a
slide.

**East-west and the issuer hostname.** A regional **internal** ALB plus a **Cloud DNS private
zone** for the console and service hostnames. Pods resolve the issuer natively, so the kind lab's
`hostAlias` bridge disappears entirely — which is the single biggest simplification versus the kind
lab, and the thing that makes this look like a real deployment.

**What we lose, and must say out loud.** No Certificate Manager, no `privateca`, no Google-managed
certificates, and Cloud DNS has no public zones, so **ACME is impossible by either challenge type**
— DNS-01 needs a public zone we cannot host, HTTP-01 needs a public name we cannot publish. So the
Tier 1 certificate is BYO and rotated by hand, and east-west certs come from a self-hosted
cert-manager internal CA. That is a genuine ISV finding and it goes in the feedback file.

**The fallback.** If probe 0.7 shows external ingress into the universe is blocked, drop Tier 1,
keep the internal ALB and private zone, and reach the consoles over `kubectl port-forward` with
`*.localtest.me` and the `hostAlias` bridge — the kind lab's mechanism, which needs nothing from
GCD's network. Worth knowing that path exists; not worth choosing it first.

Two cheap checks either way: `dig +short keycloak.localtest.me` must return `127.0.0.1` (some
resolvers strip loopback answers as DNS-rebinding protection), and **does Autopilot accept
`hostAliases`** (probe 0.9). Both matter only for the fallback now, but check them before you need
them.

### Why Track A is deferred, not cancelled

Going GCD-only today means we never see the platform work end to end with a mesh, so when something
breaks we will not know whether it is GCD or us. Track A on GKE Standard is a few hours and gives a
known-good baseline plus the A-minus-B delta that is the actual feedback deliverable for Google.
Recommend scheduling it as the next session rather than dropping it.

---

---

## Lead with the constraint: the mesh question is already decided

You asked for "Istio ambient OR Google's Istio if we can't use Solo". On Google Cloud Dedicated
the answer is **neither**, and it is not a close call. Four independent doors, all shut:

| Option | Status on GCD Berlin | Evidence |
|---|---|---|
| Solo Istio **ambient** | Blocked | `istio-cni` needs hostNetwork + `SYS_ADMIN`; `ztunnel` needs `SYS_ADMIN`/`NET_ADMIN`/`runAsUser: 0`. GKE on GCD is Autopilot-only, which rejects both. |
| Autopilot **privileged allowlist** to unblock the above | Blocked, and worse than blocked | `/kubernetes-engine/docs/tpc-differences`: *"Creating and installing allowlists to run privileged workloads in Autopilot clusters is not supported."* The `WorkloadAllowlist` / `AllowlistSynchronizer` mechanism does not exist in GCD. |
| Solo Istio **sidecar** | Blocked | `istio-init` needs `NET_ADMIN`+`NET_RAW`; Autopilot rejects it. The CNI-based alternative is the door above. |
| **Google's Istio** (Cloud Service Mesh) | Does not exist here | `/kubernetes-engine/docs/tpc-differences`: *"Cloud Service Mesh is unavailable."* `mesh`/`anthos`/`gkehub` are all absent from `gcloud services list --available`. |

Two further details worth having in your head before you say any of this to Google or a customer:

- **Even on public GCP, Autopilot has no Istio option.** The approved open-source Autopilot
  allowlists are exactly two, `Grafana/alloy/*` and `Grafana/beyla/*`. Istio is not among them, and
  no service mesh appears on the ~21-vendor Autopilot partner allowlist either. So "run ambient on
  Autopilot" is not a GCD-specific gap; GCD's gap is that it removes the *mechanism* by which the
  gap could ever be closed.
- **Cloud Service Mesh is sidecar-only anyway.** Google's own docs say Autopilot requires *managed*
  CSM (the in-cluster control plane needs Standard), and CSM does not support Istio ambient mode. So
  "use Google's Istio" would not have got you ambient even on public GCP Autopilot.

**Consequence for the lab.** Step 6 of the kind lab (Gloo Operator → `ServiceMeshController`
ambient → `enterprise-agentgateway-waypoint`) cannot run on GCD, and the tool-level authz demo in
`accesspolicy-on.sh` depends on it: a kagent `AccessPolicy` is inert until the kmcp translator
provisions a waypoint, and a waypoint only intercepts traffic if ztunnel is redirecting it.

**But the security outcome survives, via a different shape.** agentgateway in **standalone** mode
is a plain Deployment with no privileged anything (verified: no `privileged`, `NET_ADMIN`,
`SYS_ADMIN`, `hostNetwork`, `hostPath` or `runAsUser: 0` anywhere in its manifests), and it does
MCP tool-level authorization natively:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: everything-server-mcp
  namespace: mcp
spec:
  mcp:
    targets:
      - name: everything-server
        static:
          host: everything-server.mcp.svc.cluster.local
          port: 8080
          path: /mcp
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-tool-rbac
  namespace: mcp
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: everything-server-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'jwt.groups.exists(g, g == "admin")'
            - 'jwt.team == "dev" && mcp.tool.name in ["sum","echo"]'
```

Tools that match no expression are filtered out of `tools/list` and short-circuited on
`tools/call` with JSON-RPC `-32602`. That is the same enforcement the waypoint gives you. The
difference is **transparency**: the waypoint intercepts whatever the agent dials, whereas here the
agent must be pointed at the gateway. With kagent that is a one-line change — a
`RemoteMCPServer` whose URL is the gateway rather than the MCP Service.

So the honest framing, and it is a good one: *on GCD you keep tool-level authorization and the
audit trail, you lose transparent interception and mTLS between workloads.* That trade is a feedback
finding, not a dead end.

---

## Scope for today, honestly

Maximum service coverage plus GCD-only plus self-hosted Gemma is three hard things at once on an
unproven cloud. The coverage is worth it, but it will not all land today. Realistic ordering:

**Today.**

1. Phase 0 probes — 17 of them now. **0.10 GPU quota**, **0.12 LoadBalancer external IP** and
   **0.15 service agents** are the three that reshape the plan if they fail.
2. `tofu apply` 1a (KMS, network, NAT, DNS, buckets) and 1b (service agents).
3. `tofu apply` 1c: Artifact Registry, Cloud SQL, **Autopilot cluster**, IAM, observability.
4. Mirror images. Cluster baseline: cert-manager, External Secrets, Prometheus + Grafana.

**Next session.** Keycloak → kagent → mgmt chart → AgentRegistry → agentgateway → ingress → edge,
then the MCP + agent + tool-authz proof, then the model.

Getting through step 4 today with real KMS, real NAT, real Cloud SQL and a real cluster is a good
day. Trying to reach the agent demo as well is how we end up with six half-configured services and
no findings. If Phase 0 throws, we stop and the throw becomes the finding — also a good day.

---

## Phase 0 — GCD preflight (the gate, ~60 min, nothing else starts until this is done)

None of these have been tested in Berlin. Any one of them failing changes the plan, so probe before
building. Each is a single command against `eu0:soloio-eval`.

| # | Question | Probe | If it fails |
|---|---|---|---|
| 0.1 | Can we create a GKE Autopilot cluster at all? | `gcloud container clusters create-auto` in `u-germany-northeast1` | Stop; it is a blocker finding on its own |
| 0.2 | Does a pod have public internet egress? | Cloud NAT + one pod, `curl -sI https://ghcr.io` | Everything must be mirrored in-universe first |
| 0.3 | Can nodes pull from `ghcr.io` / `us-docker.pkg.dev` directly? | a Deployment on an unmirrored image | Mirror everything into Artifact Registry up front |
| 0.4 | **Does `helm push` work against Artifact Registry?** | `helm push` a chart to `u-germany-northeast1-docker.pkg-berlin-build0.goog/...` | Ship charts as files; images only via `docker push` |
| 0.5 | What is the Hyperdisk Balanced StorageClass called? | `kubectl get storageclass` | Determines whether bundled Postgres/ClickHouse can have a PVC |
| 0.6 | Does Autopilot admission accept the ClickHouse and Postgres pods? | dry-run the mgmt + registry charts | Move Postgres to Cloud SQL, ClickHouse to ephemeral |
| 0.7 | Is a regional external ALB reachable from Tom's laptop? | Gateway with an external IP, curl from outside | Fall back to `kubectl port-forward` or a bastion |
| 0.8 | ~~Does the `eu0:` prefix survive a docker reference?~~ **ANSWERED: no.** | reproduced locally, no GCD access needed | Docker rejects `<host>/eu0:soloio-eval/...` with `invalid reference format` before any network call — a colon is illegal in a path component. `.env.local` now builds `AR_PREFIX` from `PROJECT_SHORT`. Written up as `feedback/google/02`. **Still open:** whether AR *routes* the unprefixed form to `eu0:soloio-eval` |
| 0.9 | Does Autopilot accept `hostAliases`? | apply a pod with `spec.hostAliases`, check it schedules | The whole `localtest.me` issuer bridge collapses. Fall back to a Cloud DNS private zone, which then makes probe 0.7 load-bearing |
| 0.10 | **Is there any GPU quota?** | `gcloud compute regions describe "$UNIVERSE_REGION" --format='table(quotas)'` | No A3/H100 today. CPU inference on C3 is the fallback; the quota request needs the support channel, which needs the Assured Workloads folder — 48 business hours minimum |
| 0.11 | Do pods resolve public DNS names? | `nslookup ghcr.io` from a pod | Tells us whether any public-name dependency is possible at all. Cheap, record it |
| 0.12 | **Does a `Service type=LoadBalancer` get an external IP?** | one Service, watch `.status` | No Tier 1 edge. Fall back to internal ALB + port-forward |
| 0.13 | Are the **GKE Gateway classes** present? | `kubectl get gatewayclass` | If `gke-l7-regional-external-managed` is missing, wire the ALB by hand in OpenTofu against a standalone NEG instead of via GKE |
| 0.14 | Can we create a **regional** Cloud Armor policy and a **regional** self-managed cert? | `gcloud compute security-policies create --region`, `... region-ssl-certificates create` | Tier 1 loses WAF and/or TLS; document and move on |
| 0.15 | **Do JIT service agents exist / can we create them?** | `gcloud beta services identity create --service=sqladmin.googleapis.com` etc. | Every CMEK binding fails. Fall back to Google-owned encryption and make it a finding |
| 0.16 | Are **Access Transparency** and **Access Approval** actually configurable? | `gcloud logging`/`gcloud access-approval settings get` | Lose the two most quotable sovereignty controls. Either way it is a finding |
| 0.17 | Does **Workforce Identity Federation** accept a second provider (Solo's own IdP)? | create a provider in the existing pool | Stay on the shared bootstrap ID; reframe finding as an onboarding gap |

Write the verbatim output of 0.1–0.4 into `feedback/google/evidence/`. 0.4 in particular has been
an open question for days and is the cheapest test in the repo.

**Registry host to confirm.** The docs give the domain as `pkg-berlin-build0.goog` (replacing
`pkg.dev`), so the repo host *should* be `u-germany-northeast1-docker.pkg-berlin-build0.goog`.
`.env.local` now derives `AR_HOST` that way, but the `<region>-docker` prefix is a public-GCP
convention and is not confirmed for Berlin. Get the real value from:

```bash
gcloud artifacts repositories describe "${AR_REPO}" \
  --location="${AR_LOCATION}" --format='value(registryUri)'
```

Probe 0.8 is the one I would not have predicted and it could be disruptive: `AR_PREFIX` is built as
`${AR_HOST}/${PROJECT_ID}/${AR_REPO}`, and `PROJECT_ID` is `eu0:soloio-eval`. Docker's reference
grammar allows a colon in the host (as a port) and as the tag separator, but **not inside a path
component**, so `…/eu0:soloio-eval/solo/img:tag` may simply be rejected by docker, containerd,
crane and Helm's OCI client alike. If it is, that is a first-class ISV finding — the universe
prefix would be incompatible with the standard container toolchain — and the workaround is
whatever AR actually expects in the path (likely the unprefixed `soloio-eval`).

---

## Service coverage: all 31, and what each one carries

Berlin preview ships 31 enableable services. This is the whole list, with the job each one does in
the template. **24 of the 31 get a real role**; the rest are plumbing or genuinely not applicable.
Anything marked ⚠ is a probe, not a plan.

| Service | Role in the template |
|---|---|
| `compute` | The workhorse. VPC, subnets, Cloud Router, **Cloud NAT** (the only egress), **regional external ALB** + static Premium IP + **self-managed regional TLS cert**, **regional internal ALB**, **Cloud NGFW** rules, Hyperdisk Balanced, and the A3/C3 capacity Autopilot schedules onto. |
| `container` | GKE Autopilot cluster. |
| `networksecurity` | **Cloud Armor Standard** regional security policy on the external ALB. No Enterprise, so no Adaptive Protection, bot management, threat intel or address groups — state that. |
| `artifactregistry` | Docker repo, CMEK-encrypted: mirrored Solo images plus our own MCP server and agent images. Standard mode only, so no pull-through mirror. |
| `sqladmin` | **Cloud SQL Postgres Enterprise Plus** for AgentRegistry, CMEK-encrypted, reached over **Private Service Connect** (private services access does not exist here). |
| `cloudkms` | The spine of the sovereignty story. One key ring, separate keys for Cloud SQL, Cloud Storage, Artifact Registry, and the log bucket. Plus **envelope encryption for the Solo license keys and LLM credentials**, which is the only answer available given there is no Secret Manager. |
| `storage` / `storage-component` | OpenTofu state, Gemma weights (mounted via the Cloud Storage FUSE CSI driver), MCP artefacts, and an archive bucket for exported traces. All CMEK. |
| `dns` | **Private zone** for the console and service hostnames — this is what removes the `hostAlias` bridge. Also a Service Directory DNS zone. Public zones do not exist. |
| `servicedirectory` | Register the MCP servers, the gateway and the model endpoint as a real service registry. Nice tie-in: agentregistry is the *governance* catalogue, Service Directory is the *network* catalogue, and they are complementary. |
| `pubsub` | Log sink destination. It is one of only three sink targets available (project, log bucket, Pub/Sub — **not** BigQuery, **not** GCS), so it is the hinge of the audit-export story. |
| `bigquery` / `bigquerystorage` | Agent and tool-call audit analytics: Pub/Sub → a subscriber → BigQuery, since Logging cannot sink to BigQuery directly. Also the vector-search substrate for RAG later, matching Google's own GCD blueprints. |
| `bigqueryreservation` | A small reservation so the analytics path is not on-demand slots. Also the one place spend-based CUDs apply. |
| `logging` | Cloud Audit Logs, a **CMEK-encrypted log bucket with custom retention**, log views, and project + aggregated sinks. This is the DORA/NIS2 evidence path, such as it is. |
| `monitoring` | PromQL queries against what GCD does collect. Everything else is self-hosted Prometheus + Grafana, because Cloud Monitoring cannot ingest custom, Prometheus or OTel metrics. |
| `accesscontextmanager` | **VPC Service Controls perimeter** around the project. ⚠ Off by default and applied last — see the warning below. |
| `iam` / `iamcredentials` / `sts` | Per-component service accounts, **Workload Identity Federation for GKE** (`<project>.eu0.svc.id.goog`), service-account impersonation, and — the interesting one — **federating Solo's own IdP via Workforce Identity Federation** so we get per-person attribution instead of the shared bootstrap ID. |
| `orgpolicy` | Predefined org policies only (no custom, no managed constraints in GCD): resource location restriction, shielded VMs, restrict external IPs where we do not need them. The governance layer of the template. |
| `essentialcontacts` | Notification contacts for security and technical categories. Cheap, and it ticks a box a regulated buyer asks about. |
| `cloudresourcemanager` | Folder structure around the project — the beginnings of a landing zone, and the thing Fabric FAST would generate. |
| `cloudbilling` | Billing account link. Budgets are an open question here since billing is operator-run, not Google-run. ⚠ |
| `autoscaling` | HPA for the MCP servers and the model deployment. Autopilot drives node scaling itself. |
| `serviceusage` / `cloudapis` / `cloud` / `discovery` | Plumbing: enabling APIs, and the Discovery service the client libraries use. Enabled, not architected. |
| `apikeys` | No role. We use OIDC and service accounts throughout; an API key would be a downgrade. |

**Beyond the API list**, two things the docs say exist and are worth turning on because they are
pure sovereignty signal: **Access Transparency** (audit of provider access) and **Access Approval**
(the partner cannot touch our data without our approval). Both appear in Berlin's `/products` and
Access Approval shows up in the VPC-SC supported-services list. If they work, they are the single
most quotable controls in the whole template for a German buyer.

### The one CMEK we cannot do, and why it matters

Everything above gets a customer-managed key **except GKE itself**. Berlin's GKE differences page
says *"Encrypting Secrets at the application layer is not supported"*, so
`database_encryption { state = "ENCRYPTED" }` on the cluster will fail. That is precisely the gap
that makes the missing Secret Manager worse than it first looks: Solo license keys, LLM
credentials, TLS private keys and the AgentRegistry database password all land in **plaintext etcd
Secrets**, with no application-layer encryption and no managed secret store to move them to. Our
workaround is Cloud KMS envelope encryption into a Secret, which protects the value at rest in our
own storage but not in etcd. Say that plainly rather than implying CMEK covers it.

### VPC Service Controls: valuable, and the one thing that can lock us out

A service perimeter is the most persuasive control in the template and the most dangerous thing in
this plan. GCD's VPC-SC is also weakened — no standalone or custom access levels, no perimeter
bridges, and ingress/egress rules **cannot reference identities, VPC networks, service methods, or
internal-IP access levels**. Combine a misconfigured perimeter with a shared bootstrap identity, a
console that lies about IAM until you re-login, and **no Policy Troubleshooter** (Policy
Intelligence is absent), and a bad apply is genuinely hard to diagnose your way out of.

So: build it, keep it `enable_vpc_sc = false`, apply it **last**, in **dry-run mode first**, and
only once the support channel exists. Do not let it near the critical path.

### Should we add kgateway as well?

You said agentgateway, kagent and agentregistry, and that is the right core. But kgateway v2.4.4 is
deployable here and it would make the template more complete and more portfolio-shaped: **kgateway
as the north-south application gateway** for the consoles and the blueprint web app, **agentgateway
as the agentic data plane** for MCP, A2A and LLM traffic. Two products, two clearly distinct jobs,
no overlap to explain away.

The argument against is that agentgateway is itself a Gateway API implementation and can serve the
consoles perfectly well, so kgateway adds a component without adding a capability. **Recommendation:
skip it in the first pass, add it in the second** once the core is green — and if we add it, add it
because the template gains a real separation of concerns, not to inflate the product count.

Same reasoning for **agentevals** (worth adding once an agent actually runs) and **Agent
Substrate** (⚠ its `CSIDriverConfig` implies a third-party CSI driver, which Autopilot will not
admit — test before promising the sandboxed-agent story to anyone).

---

## Target architecture

Seven products, one namespace each, exactly as the kind lab, with the GCD substitutions called out.

| Namespace | What lives there | Track A (GKE Standard) | Track B (GCD Autopilot) |
|---|---|---|---|
| `keycloak` | Keycloak 26.3, single OIDC issuer, realm `agentregistry` | as-is | as-is |
| `kagent` | Solo Enterprise for kagent: controller, tool server, OBO signing key | as-is | as-is |
| `solo-enterprise` | mgmt chart: ClickHouse, OTel collectors, Enterprise UI | as-is | ClickHouse persistence decision from 0.5/0.6 |
| `agentregistry-system` | AgentRegistry server + Postgres + ClickHouse + collector | bundled Postgres | **Cloud SQL Postgres** (`sqladmin` is present; PSC or private IP) |
| `agentgateway-system` | enterprise agentgateway controller + ingress Gateway | as-is | as-is |
| `gloo-system` | Gloo Operator, waypoint `AgentgatewayParameters` | as-is | **omitted** |
| `istio-system` | Solo Istio ambient: istiod, ztunnel, CNI | as-is | **omitted — cannot run** |
| `mcp` | the MCP servers under test | behind a waypoint | behind a standalone agentgateway |
| `model` | self-hosted Gemma + vLLM | n/a | A3/H100, or C3 CPU fallback |
| `observability` | Prometheus + Grafana | optional | **mandatory** — Cloud Monitoring cannot ingest our metrics |
| `cert-manager` | internal CA for east-west certs | optional | **mandatory** — no Certificate Manager, no `privateca`, no ACME |
| `external-secrets` | ESO with a Cloud KMS backend | optional | **mandatory-ish** — the only answer to no Secret Manager |

### The infrastructure tiers, north to south

```
                    internet
                        │
        ┌───────────────▼────────────────┐
        │ static Premium Tier IP          │  compute
        │ regional external ALB           │  compute  (no global/classic in GCD)
        │   + Cloud Armor Standard        │  networksecurity
        │   + self-managed regional cert  │  compute  (BYO — no Certificate Manager)
        └───────────────┬────────────────┘
                        │  zonal NEG
        ┌───────────────▼────────────────┐
        │ agentgateway  (Solo)            │  JWT · MCP tool authz · LLM policy
        │   GatewayClass                  │  rate limits · budgets · audit
        │   enterprise-agentgateway       │
        └───────┬───────────────┬────────┘
                │               │
      ┌─────────▼──────┐  ┌─────▼──────────┐
      │ MCP servers    │  │ Gemma + vLLM   │  A3/H100 or C3 CPU
      │ (KMCP)         │  │ weights via    │  storage + GCS FUSE CSI
      └────────────────┘  │ Cloud Storage  │
                          └────────────────┘
                │
      ┌─────────▼───────────────────────────────────────────┐
      │ kagent · agentregistry · Keycloak · Enterprise UI    │
      └─────────┬───────────────────────────────────────────┘
                │
    ┌───────────▼─────────┐   ┌──────────────┐   ┌──────────────────┐
    │ Cloud SQL Postgres  │   │ Artifact Reg │   │ Cloud DNS private│
    │ Enterprise Plus     │   │ Docker, CMEK │   │ zone             │
    │ CMEK · PSC          │   └──────────────┘   └──────────────────┘
    └─────────────────────┘

  audit:  Cloud Audit Logs → CMEK log bucket (custom retention)
                           → log sink → Pub/Sub → BigQuery
  egress: Cloud Router + Cloud NAT (Public NAT only, IPv4 only)
  keys:   Cloud KMS key ring — one key per service, plus envelope
          encryption for license keys (no Secret Manager)
  guard:  Cloud NGFW Standard · VPC-SC perimeter (last, dry-run first)
          Org Policy · Essential Contacts · Access Transparency/Approval
```

### What changes versus the kind lab, and why

1. **No kind, no host registry.** kind gave you a `localhost:5001` registry that nodes reached over
   the docker network, and `kind load docker-image` for the Solo Istio images. On GKE both go away:
   one **Artifact Registry** Docker repo is the single source for `arctl build --push` images and
   for any mirrored third-party images. GKE nodes authenticate to Artifact Registry with the node
   service account, so no imagePullSecrets — but on GCD there are **no remote or virtual
   repositories**, so there is no pull-through mirror and anything not mirrored must be pullable
   over egress (probe 0.3).
2. **No `*.localtest.me`, no `extraPortMappings`.** The kind lab leaned on `localtest.me` resolving
   to `127.0.0.1` plus a `hostAlias` bridging the issuer in-cluster. On GKE we need a real hostname
   that resolves *identically* in the browser and inside the cluster, because Keycloak stamps
   `iss` and every product validates it. Options in the questions below.
3. **No NodePort pinning.** `06-gateway.sh` patches the Gateway Service to NodePort 30080. On GKE
   the Gateway Service becomes a real LoadBalancer; drop the patch. Note GCD has **regional load
   balancers only** — no global, no classic, no Cloud CDN.
4. **Storage.** kind used ephemeral everything. On GCD, Hyperdisk Balanced is the only disk type;
   `clickhouse.persistentVolume.enabled=false` still works but loses trace history on restart.
5. **TLS.** Track A can use a Google-managed certificate. **Track B cannot**: no Certificate
   Manager, no Google-managed certs, no `privateca`, and Cloud DNS has **no public zones**, so
   ACME DNS-01 is not available either. Track B is HTTP-only, or BYO cert loaded as a Secret onto a
   regional self-managed cert. Flag this — it is a real ISV finding.
6. **Observability.** Cloud Monitoring in GCD cannot ingest custom, Prometheus or OpenTelemetry
   metrics, and Cloud Logging cannot take log-based metrics or sink to BigQuery/GCS. The lab's
   ClickHouse + OTel collector stack is therefore not a nice-to-have on GCD, it is the *only*
   telemetry path. That is a good story: the Solo mgmt chart is what gives a GCD customer agent
   observability at all.

---

## Repo layout

Infrastructure goes in `infra/tofu/` with profile modules, per the decision above. The lab-specific
install chain and manifests stay in `poc/` until they have worked twice, then get promoted by
rewriting (repo rule: never import from `poc/` into `demos/` or `infra/`).

```
infra/tofu/
  providers.tf             google provider; universe_domain from var, pinned high
  variables.tf             profile = "gcd-autopilot" | "gcp-standard"
  main.tf                  module wiring, switched on var.profile
  outputs.tf               cluster name, registry uri, sql connection name
  backend.tf               GCS state bucket (storage is available in GCD)
  profiles/
    gcd-autopilot.tfvars   berlin, u-germany-northeast1, eu0: prefix
    gcp-standard.tfvars    deferred Track A
  modules/
    kms/                   key ring + per-service keys, and the envelope key
    network/               VPC, subnet, Cloud Router, Cloud NAT, Cloud NGFW rules
    gke-autopilot/         Autopilot cluster
    gke-standard/          Standard cluster + node pool (Track A, deferred)
    registry/              Artifact Registry Docker repo, CMEK
    cloudsql/              Postgres Enterprise Plus, CMEK, PSC
    storage/               buckets: state, model weights, artefacts, archive. CMEK
    dns/                   Cloud DNS *private* zone (public zones do not exist here)
    iam/                   per-component service accounts + Workload Identity bindings
    observability/         log bucket (CMEK), sinks, Pub/Sub topic, BigQuery dataset
    edge/                  static IP, regional external ALB, Cloud Armor, regional
                           TLS cert, NEG wiring, regional internal ALB
    servicedirectory/      namespace + services for the gateway, MCP servers, model
    governance/            Org Policy, Essential Contacts, Access Transparency
    vpcsc/                 VPC-SC perimeter. OFF BY DEFAULT. Dry-run first.

poc/2026-09-agentic-platform/
  PLAN.md                  this file
  scripts/
    00-preflight.sh        Phase 0 probes needing no cluster; writes evidence
    10-tofu.sh             tofu init/plan/apply against a profile, emits .env.tofu
    15-mirror-images.sh    mirror the image set into Artifact Registry
    20-cluster-probes.sh   get-credentials, then the in-cluster probes (0.5, 0.6, 0.9, 0.11)
    25-cluster-baseline.sh cert-manager (internal CA), External Secrets + KMS,
                           Prometheus + Grafana. All three are mandatory on GCD.
    30-keycloak.sh         realm import, scrape the two client secrets
    40-kagent.sh           kagent-enterprise CRDs + controller, OBO key
    45-telemetry.sh        solo-enterprise management chart (OTel + UI)
    50-agentregistry.sh    agentregistry-enterprise against Cloud SQL over PSC
    60-model.sh            self-hosted Gemma (CPU on C3, or A3/H100 if quota)
    70-agentgateway.sh     enterprise agentgateway CRDs + controller
    80-ingress.sh          Gateway + HTTPRoutes, NEG annotation, private DNS records
    85-edge.sh             tofu apply of the edge module once the NEG exists
    90-mcp-agent.sh        publish MCP server + scaffold/deploy agent
    95-authz-on.sh         MCP tool-level authz at the standalone gateway
    95-authz-off.sh        revert
    99-teardown.sh         tofu destroy + orphan sweep
    lib.sh                 ported from solo-demos, kind bits removed
  yaml/
```

Note there is no `60-mesh.sh`. On GCD that slot is the model instead — which is a neat summary of
the whole engagement.

`lib.sh`, the realm JSON, the MCP servers and the agent scaffold all come from
`solo-demos/agentregistry-agentcore-kind/deploy/` — copy, do not import (repo rule: never import
from `poc/` into `demos/`, and equally do not couple this to another repo's paths).

**OpenTofu, not Terraform.** Same provider, `tofu` binary. Two provider notes that bite on GCD:
`universe_domain` must be set on the provider, and **pin the google provider high** — it was
originally wired only into the SDK code path, so older versions silently talk to `googleapis.com`
for plugin-framework resources. Also: BigQuery's differences page claims "Terraform support is
unavailable" in GCD; we are not using BigQuery here, but expect rough edges and record them.

---

## Execution phases

### Phase 1 — infrastructure (OpenTofu), in four applies

Split deliberately, because a single `apply` that touches KMS, VPC-SC and a cluster is
undebuggable on an unproven cloud, and because the JIT service-agent problem forces an ordering.

**1a. Foundation.** Key ring and keys first, then VPC, subnet with secondary ranges, Cloud Router,
**Cloud NAT**, Cloud NGFW rules including the GKE ranges `34.3.144.0/23` and `34.3.151.0/26`, the
Cloud DNS private zone, and the Cloud Storage buckets. No default network exists in a GCD project,
so the network module is mandatory, not optional.

**1b. Service agents — the step that is easy to miss.** In GCD, **service agents are provisioned
just-in-time on first resource creation, not when the API is enabled**. Every CMEK binding needs
the consuming service's agent to already exist and hold `roles/cloudkms.cryptoKeyEncrypterDecrypter`
on the key. So before any CMEK resource: create the agents explicitly, grant them, then apply. The
GKE differences page spells this out and even names the GKE one,
`service-PROJECT_NUMBER@container-engine-robot.eu0-system.iam.gserviceaccount.com`. Done with
`gcloud beta services identity create --service=…` per service, from `10-tofu.sh`, not from
OpenTofu, so failures are legible.

**1c. Platform.** Artifact Registry (CMEK), Cloud SQL Enterprise Plus + PSC endpoint (CMEK), the
Autopilot cluster, Service Directory namespace, log bucket + sinks + Pub/Sub topic + BigQuery
dataset, per-component service accounts with Workload Identity Federation bindings, Org Policy,
Essential Contacts.

**1d. Edge.** Static external IP, regional external ALB, Cloud Armor policy, self-managed regional
TLS certificate, NEG wiring to the agentgateway Service, regional internal ALB, and the private
DNS records. Some of this can only be created after the cluster exists and agentgateway has
published a Service, so it lands last.

**Deliberately not in Phase 1: the VPC-SC perimeter.** `enable_vpc_sc = false`. Apply it after
everything works, dry-run first, and only once the support channel exists — see the warning above.

Outputs land in `deploy/.env.tofu` for the shell scripts, same pattern as
`solo-demos/agentgw-agentcore-multi-account-kind`. Remember the `eu0:` project prefix everywhere and
quote it.

### Phase 2 — images

Build the image list from `infra/helm/images.txt` plus the chart image sets. Mirror with
`scripts/mirror-images.sh` (already in the repo) into Artifact Registry, then template every values
file at the mirrored host. Never hardcode `ghcr.io`, `pkg.dev` or `us-docker.pkg.dev` into anything
that runs in-universe. If probe 0.3 says nodes can pull `us-docker.pkg.dev` directly over NAT, we
can skip mirroring for Track B *for the lab* — but do not build the demo that way, because a real
customer will be egress-restricted.

### Phase 3 — platform install, in dependency order

The order is a dependency chain and out-of-order failures do not look like their cause:

1. **Keycloak** — realm `agentregistry`, five clients (`ar-backend`, `ar-ui`, `ar-cli-password`,
   `kagent-backend`, `kagent-ui`), one `admins` group, group-membership mapper emitting **`Groups`
   with a capital G**, split audience mappers (`ar-*` → `aud: ar-backend`, `kagent-*` →
   `aud: kagent-backend`). Scrape the two confidential client secrets from the admin API.
2. **Solo Enterprise for kagent** — CRDs then controller. RSA OBO signing key in a Secret that
   **must** be named `jwt`. `oidc.skipOBO=false`. Role-mapper CEL reads `claims.Groups`. Do not
   pass `--wait`: the controller does OIDC discovery at startup, so install, fix name resolution,
   then wait.
3. **Solo Enterprise management chart** — ClickHouse, OTel collectors, Enterprise UI.
   `products.kagent.enabled=true` and `products.kagent.namespace=kagent` or the UI manages nothing.
4. **AgentRegistry Enterprise** — `oidc.roleClaim=Groups`, `oidc.superuserRole=admins`, and
   `kagent.outboundAuth.oidc` pointed at `kagent-backend` so the deploy-to-kagent call carries the
   right audience. Track A bundled Postgres; Track B `database.postgres` → Cloud SQL.
5. **Track A only: Solo Istio ambient** — Gateway API *experimental* CRDs (delete the
   `safe-upgrades` ValidatingAdmissionPolicy first, retry with backoff), Gloo Operator, then a
   `ServiceMeshController` with `dataplaneMode: Ambient`. The SMC `version` is the **stripped**
   form (`1.29.2-patch0`); the operator appends `-solo`. No `kind load` needed on GKE, but the
   images must be reachable — mirror them.
6. **enterprise agentgateway** — CRDs then controller. Track A also sets `CLUSTER_ID`/`NETWORK` via
   an `AgentgatewayParameters` on the waypoint GatewayClass so every waypoint gets its identity.
   Track B skips that entirely and uses the plain `enterprise-agentgateway` GatewayClass.
7. **Ingress Gateway** — one Gateway, three HTTPRoutes (Keycloak, AgentRegistry on `:12121`,
   Enterprise UI). Real LoadBalancer, no NodePort patch.

### Phase 4 — the actual test: MCP server + agent through agentgateway

This is the part you care most about and it is the same on both tracks up to the enforcement step.

1. `arctl user login` against the `ar-cli-password` client.
2. `arctl build ./mcp/everything-server --push` → Artifact Registry. Tools: `sum`, `echo`,
   `to_uppercase`, `reverse_text`, plus `printenv` as the one that should get denied.
3. `arctl apply -f mcp/everything-server/mcp.yaml` → publishes the `MCPServer` to the catalog.
4. `arctl init agent … --mcp everything-server@latest`, then deploy it to the kagent runtime from
   the registry. The registry mints a client-credentials token with `aud: kagent-backend` to call
   the kagent controller.
5. **Ask the agent to list its tools**, then call `sum`. Baseline: all tools visible.
6. **Enforce tool-level authz and re-ask.** Expect only the allowlisted tool to be visible and
   every other call to fail:
   - **Track A:** kagent `AccessPolicy` (`action: ALLOW`, `targetRef.kind: MCPServer`,
     `tools: [sum]`) + label the MCPServer `kagent.solo.io/waypoint=true`. The kmcp translator
     provisions the waypoint Gateway, HTTPRoute and `AgentgatewayBackend`, and compiles the
     AccessPolicy into an `EnterpriseAgentgatewayPolicy`. Restart the agent so it re-lists.
   - **Track B:** `AgentgatewayBackend` with `spec.mcp.targets` + `AgentgatewayPolicy` with
     `backend.mcp.authorization`, and point the agent's `RemoteMCPServer` at the gateway.
7. Confirm the trace lands in the Enterprise UI Tracing tab (ClickHouse via the OTel collector).

### Model provider: self-hosted, with a CPU fallback for today

Decision is self-hosted in-universe, no Anthropic. That is the right call for a sovereign demo and
it matches what Google's own GCD reference architectures do. But be ready for the quota wall.

**The target.** Gemma 3 27B IT on `a3-highgpu-8g-nolssd` (NVIDIA H100 80GB ×8, no Local SSD, 800
Gbps), served by vLLM, requested through the **Accelerator** compute class — one of only two
predefined compute classes available on GCD Autopilot. Fronted by an agentgateway LLM backend so
kagent talks to the gateway, not the model, and every prompt and token is policy-checked and
audited. That last part is the whole Solo argument and it is what Google's blueprints leave out.

**The likely blocker.** A3/H100 quota on a preview project is almost certainly zero by default, and
in GCD **quota increases can only be requested through GCD support** — which requires the public
GCP org plus Assured Workloads folder plus empty support project, then up to 48 business hours.
So probe 0.10 first. If quota is zero, Gemma-on-H100 is not happening today no matter what else we
do, and standing up the support channel becomes the highest-value non-technical task of the week.

**The fallback, which is Google's own advice.** The Compute Engine differences page says outright:
*"Consider doing CPU inferencing if A3 High or A3 Edge is too large for your workload."* So serve a
small Gemma (270M or 1B, instruction-tuned) on C3 CPU via vLLM or llama.cpp. It is a poor model and
a fine demo: the agent gets a real, in-universe, no-egress model endpoint, the gateway enforces
policy on real LLM traffic, and swapping to 27B on H100 later is a values-file change. Do not let
the model size block the platform proof.

**Weights.** Gemma weights have to get into the universe. Either pull from Hugging Face over Cloud
NAT egress (probe 0.2) into a Cloud Storage bucket and mount from there, or push them as an OCI
artifact to Artifact Registry. Bucket is simpler; note Cloud Storage FUSE CSI works on GKE
`1.36.0-gke.1266000`+ with `skipCSIBucketAccessCheck: "true"`. Also note Gemma weights are
gated on Hugging Face, so that needs a token — a secret, in a universe with no Secret Manager.

### Phase 5 — later, once Phase 4 is green

- Upgrade the model from CPU Gemma to 27B on A3/H100, once quota lands.
- Stand up Track A on GKE Standard and write the delta up as a numbered feedback finding.
- Take Google's `demos/tax-office` or `demos/insurance` blueprint and put our stack in front of it.
- Cloud DNS private zone instead of the `localtest.me` bridge, as the customer-shaped variant.

---

## Version matrix to pin

The kind lab was validated 2026-06-21. Several of these are now old, and `solo-demos/versions.env`
(2026-06-18) is older still. Re-verify each before pinning anything customer-facing — and note the
**Enterprise product lines are versioned separately from the OSS lines** in this repo's CLAUDE.md
table, which currently lists only the OSS ones.

| Component | Lab-tested | Latest known | Decision |
|---|---|---|---|
| Solo Enterprise for kagent | 0.4.3 | check | pin lab-tested first, upgrade after green |
| Solo Enterprise management | 0.4.3 | check | as above |
| AgentRegistry Enterprise | 2026.6.1 | 2026.8.0 (used 2026-09-02) | try 2026.8.0 |
| enterprise agentgateway | v2026.5.1 | **v2026.8.2** | v2026.8.2 |
| Gloo Operator | 0.5.2 | check | Track A only |
| Solo Istio | 1.29.2-patch0 | 1.30.x stable | Track A only |
| Gateway API | v1.4.0 | v1.6.1 | v1.6.1 std; experimental only on Track A |
| arctl | v2026.6.1 | check | v2026.6.1 |
| Keycloak | 26.3 | 26.x | 26.3 |

API-group trap worth writing down now: the OSS CRDs are `agentgateway.dev/v1alpha1`
(`AgentgatewayBackend`, `AgentgatewayPolicy`, `AgentgatewayParameters`), but the Enterprise wrappers
are **`enterpriseagentgateway.solo.io`** (`EnterpriseAgentgatewayPolicy`,
`EnterpriseAgentgatewayBackend`, `EnterpriseAgentgatewayParameters`), with `AuthConfig` on
`extauth.solo.io`, `RateLimitConfig` on `ratelimit.solo.io` and `WAFPolicy` on `waf.solo.io`.
Mixing the groups fails silently.

---

## Risks, ranked

1. **Autopilot cluster creation or pod egress fails in Berlin.** Phase 0 stops the plan. Cheapest
   test, highest value, do it first.
2. **No GPU quota**, and the only route to more is a support channel we have not built. Caps the
   model story at CPU inference for at least a week. Probe 0.10.
3. **The `eu0:` colon breaks docker references** (probe 0.8). If it does, nothing gets pushed or
   pulled from Artifact Registry with standard tooling and the whole image strategy changes.
4. **`helm push` unsupported** in GCD Artifact Registry (probe 0.4) — Docker, Apt and Yum are the
   only documented formats and `helm` is not in the supported-client list. Every chart install
   changes shape.
5. **`hostAliases` rejected by Autopilot** (probe 0.9) — collapses the `localtest.me` issuer
   bridge and makes external LB reachability load-bearing.
6. **Autopilot admission rejects ClickHouse or Postgres** (probe 0.6). Mitigation is already in the
   plan: Cloud SQL for Postgres, ephemeral ClickHouse.
7. **Version drift.** The lab is ~10 weeks old and Solo ships weekly. Pin lab-tested versions
   first, upgrade only once green.
8. **TLS is BYO and manual.** No Certificate Manager, no `privateca`, no Google-managed certs, and
   no public Cloud DNS zone, so **ACME is impossible by either challenge type**. Tier 1 gets a
   hand-rotated self-managed regional cert; east-west gets a self-hosted cert-manager internal CA.
   A real ISV finding.
9. **No mesh means no workload mTLS.** On GCD we get tool-level authorization and audit at the
   gateway, but not identity-based encryption between workloads. Do not let that get glossed over.
10. **VPC-SC can lock us out**, and with no Policy Troubleshooter and a shared identity it is hard
    to diagnose. Off by default, dry-run first, applied last, and not before the support channel
    exists.
11. **Scope.** Maximum coverage means ~14 OpenTofu modules and 3 mandatory self-hosted platform
    components before a single Solo product installs. The failure mode is a half-built template
    with no working demo. Mitigation: the four-stage apply, and stopping today at step 4.
