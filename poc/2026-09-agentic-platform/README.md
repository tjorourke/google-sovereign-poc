# Agentic platform on Google Cloud Dedicated — runbook

Port of `solo-demos/agentic-enterprise-platform-kind` onto real GKE in the
Berlin GCD universe, provisioned with OpenTofu, built as a **customer reference
template** rather than a minimal lab.

Read `DEMO-READINESS.md` for the current demo state and verification commands.
`deploy/inventory.json` records the live cloud resources, load balancers, charts,
images, storage, routes and policies. `PLAN.md` preserves the original reasoning.

---

## Before anything

```bash
# 1. authenticate to the universe. Two browser flows. A 404 page is CORRECT —
#    a "Login successful" page means you hit public GCP instead.
./scripts/gcd-auth.sh          # from the repo root

# 2. Solo license keys and the LLM keys live outside this repo
source ~/code/solo/secrets/secrets-envs.sh

# 3. arctl, pinned
curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh \
  | ARCTL_VERSION=v2026.6.1 sh
export PATH="$HOME/.arctl/bin:$PATH"

# 4. one-off: the OpenTofu state bucket. Cloud Storage in GCD has no default
#    location, so --location is mandatory.
source .env.local
gcloud storage buckets create "gs://${PROJECT_SHORT}-tofu-state" \
  --project "$PROJECT_ID" --location "$UNIVERSE_REGION" --uniform-bucket-level-access
```

`assert_universe` in `scripts/lib.sh` guards every script: if `universe_domain`
is not the Berlin one, or the token is dead, it stops before touching anything.

`05-validate.py` needs no credentials at all. It extracts every heredoc'd
manifest from the scripts, substitutes the shell variables, parses the YAML, and
then checks each pod spec against what Autopilot will actually admit — resource
requests present on every container, and none of `hostNetwork`, `hostPath`,
`privileged`, `allowPrivilegeEscalation`, `runAsUser: 0` or the
`SYS_ADMIN`/`NET_ADMIN`/`NET_RAW` capabilities. Worth running after any edit:
GCD has no `WorkloadAllowlist` mechanism, so there is no way to grant those
fields later, and a quoted-heredoc mistake ships a literal `${VAR}` to the
cluster. Both classes of bug have already bitten once in this repo.

**Note on WIF token lifetime.** Workforce Identity Federation refresh tokens are
short-lived. If any script stops with `invalid_grant: Refresh token has expired`,
re-run `./scripts/gcd-auth.sh` — there is no service account key to fall back on,
because WIF is the only identity path in GCD.

---

## Phase 1 — infrastructure

```bash
./scripts/05-validate.py         # offline: parse every embedded manifest +
                                 # Autopilot admission check. No cloud needed.
./scripts/08-enable-apis.sh      # a fresh GCD project has only 9 services on;
                                 # compute and container are NOT among them
./scripts/00-preflight.sh        # 17 probes, read-only, writes evidence files
./scripts/10-tofu.sh plan        # review
./scripts/10-tofu.sh apply       # foundation -> service agents -> platform
eval "$(cd ../../infra/tofu && tofu output -raw get_credentials_command)"
./scripts/20-cluster-probes.sh   # the probes that need a live cluster
./scripts/15-mirror-images.sh    # push images into Artifact Registry
./scripts/25-cluster-baseline.sh # cert-manager, External Secrets, Prom+Grafana
```

**Three probes reshape the plan if they fail.** `0.10` GPU quota decides whether
the model runs on H100 or CPU. `0.12` LoadBalancer external IP decides whether
the Tier 1 edge exists at all. `0.15` service agents decides whether CMEK is
possible. Read the summary each script prints; the verbatim output lands in
`feedback/google/evidence/`.

`10-tofu.sh apply` runs three stages in order and creates the JIT service agents
between them. That ordering is not cosmetic: GCD provisions service agents on
first resource creation rather than on API enable, so every CMEK binding needs
its consuming service's agent to exist and hold
`roles/cloudkms.cryptoKeyEncrypterDecrypter` first. A 400 about the key means
this step was skipped.

The three baseline components are **mandatory here, not optional**, because each
replaces a Google service Berlin does not have: cert-manager (no Certificate
Manager, no `privateca`, no public Cloud DNS zone, so no ACME by either
challenge type), External Secrets (no Secret Manager), Prometheus + Grafana
(Cloud Monitoring cannot ingest custom, Prometheus or OTel metrics at all).

---

## Phase 2 — the platform

Order is a dependency chain, and out-of-order failures rarely look like their
cause.

```bash
./scripts/30-keycloak.sh       # the single OIDC issuer; scrapes 2 client secrets
./scripts/40-kagent.sh         # Solo Enterprise for kagent
./scripts/45-telemetry.sh      # mgmt chart: ClickHouse + OTel + Enterprise UI
./scripts/50-agentregistry.sh  # AgentRegistry against Cloud SQL over PSC
./scripts/70-agentgateway.sh   # enterprise agentgateway, standalone path
./scripts/80-ingress.sh        # Gateway + routes + the private DNS handover
./scripts/85-edge.sh           # Tier 1: regional external ALB + Cloud Armor + TLS
```

Solo Istio ambient is installed by phases `62`, `63`, and `64` before kagent.
The approved WorkloadAllowlists are required on this Autopilot cluster.

**The DNS handover is the part to understand.** kagent, the Enterprise UI and
AgentRegistry all do OIDC discovery at startup, and they install before the
gateway exists. So `30-keycloak.sh` points `keycloak.agentic.eu0.internal` at
Keycloak's ClusterIP (pods can route to a ClusterIP) and `80-ingress.sh`
re-points the same name at the gateway once it is up. The issuer string never
changes, so no token ends up with a stale `iss`. This replaces the kind lab's
`hostAlias` bridge entirely.

---

## Phase 3 — the model, then the proof

```bash
./scripts/60-model.sh                                   # self-hosted Gemma
MODEL_PROVIDER=selfhosted ./scripts/40-kagent.sh        # re-point kagent at it
./scripts/90-mcp-agent.sh                               # MCP server + agent, baseline
./scripts/88-identity.sh                                # bob/alice and per-agent OIDC clients
# Deploy the TrustUsBank bank and SDLC workloads, then:
./scripts/92-mcp-lockdown.sh                            # waypoints + strict JWT + per-agent grants
KUBECONFIG="$PWD/deploy/console.kubeconfig" \
  python3 scripts/verify_mcp_security.py                # positive + negative live checks
```

`60-model.sh` picks its profile from the GPU quota it finds. `gpu` is
`gemma-3-27b-it` on `a3-highgpu-8g-nolssd` with the Accelerator compute class;
`cpu` is a small Gemma on C3, which is Google's own documented advice when A3 is
too large. Either way the model sits **behind agentgateway**, which is the one
thing Google's two published GCD blueprints do not do.

---

## Verified mesh and MCP enforcement

The initial ambient blocker was resolved in this preview using approved
WorkloadAllowlists. The live cluster runs Solo Istio `1.30.4-solo`, including
istiod, CNI and ztunnel. Every agent has an enterprise agentgateway waypoint.

MCP traffic uses the in-cluster Services through ambient HBONE. All nine MCP
Services require signed, expiring Kubernetes ServiceAccount JWTs with audience
`trustusbank-mcp`. A Require policy binds the JWT subject to the source's mTLS
namespace and ServiceAccount. Projected tokens rotate automatically.

Each agent/backend pair has an `EnterpriseAgentgatewayPolicy` with an explicit
tool allowlist. The catalog and controller may discover tools, not call them.
The unused kagent administrative tools backend has no agent grants. Gateway
policies hide unauthorized tools and reject direct calls to them.

Per-server ztunnel DENY policies reject connections that do not come from the
MCP waypoint. MCP backends use Service selectors, not static DNS targets:
static targets lose workload mTLS on the waypoint-to-server hop. All old edge
MCP routes are removed. Pod-IP bypasses are tested, not inferred from labels.

`95-authz-on.sh` / `95-authz-off.sh` are historical standalone experiments.
Use `92-mcp-lockdown.sh` for the Google demo. After any old deployment script is
re-run, run lockdown and verification again before presenting.

---

## Teardown

```bash
./scripts/99-teardown.sh workloads   # namespaces first, so LBs and NEGs clean up
./scripts/99-teardown.sh infra       # tofu destroy; prompts for the project id
```

KMS keys carry `prevent_destroy`, so a destroy refuses rather than orphaning
anything encrypted with them. Check for orphaned forwarding rules, addresses and
NEGs afterwards — the teardown script prints the commands.
