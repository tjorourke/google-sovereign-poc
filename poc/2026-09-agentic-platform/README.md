# Agentic platform on Google Cloud Dedicated — runbook

Port of `solo-demos/agentic-enterprise-platform-kind` onto real GKE in the
Berlin GCD universe, provisioned with OpenTofu, built as a **customer reference
template** rather than a minimal lab.

Read `PLAN.md` for the reasoning. This file is just the order of operations.

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

There is no `60-mesh.sh`. On GCD that slot is `60-model.sh` instead, which is a
fair summary of the whole engagement.

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
./scripts/95-authz-on.sh                                # tool-level authz at the gateway
./scripts/95-authz-off.sh                               # revert
```

`60-model.sh` picks its profile from the GPU quota it finds. `gpu` is
`gemma-3-27b-it` on `a3-highgpu-8g-nolssd` with the Accelerator compute class;
`cpu` is a small Gemma on C3, which is Google's own documented advice when A3 is
too large. Either way the model sits **behind agentgateway**, which is the one
thing Google's two published GCD blueprints do not do.

---

## What cannot be built here, and why

Solo Enterprise for Istio, by any route. Not a configuration problem.

| Route | Status |
|---|---|
| Istio ambient | `istio-cni` needs hostNetwork + `SYS_ADMIN`, `ztunnel` needs `SYS_ADMIN`/`NET_ADMIN`/`runAsUser: 0`. GKE on GCD is Autopilot-only and rejects both. |
| Autopilot privileged allowlist | *"Creating and installing allowlists to run privileged workloads in Autopilot clusters is not supported."* The mechanism does not exist here. |
| Istio sidecar | `istio-init` needs `NET_ADMIN`/`NET_RAW`. Same wall. |
| Cloud Service Mesh | *"Cloud Service Mesh is unavailable."* |
| GKE network policies | Listed as unavailable. Even the crude fallback is gone. |

Tracked in `feedback/google/01-autopilot-ambient-blocker.md`.

**The trap to avoid:** the `enterprise-agentgateway-waypoint` GatewayClass is
registered by the chart and a waypoint Deployment *will* schedule. But nothing
redirects traffic to it without ztunnel, so if you label an MCPServer
`kagent.solo.io/waypoint=true` the resources apply, the policy reports
`Accepted`, and **nothing is enforced**. Silent failure of a security control.
Use `95-authz-on.sh`, which enforces at the standalone gateway instead.

What survives: MCP tool-level authorization, JSON-RPC-level policy, LLM traffic
management, and the audit trail. What is lost: transparent interception and
workload mTLS. Say both.

---

## Teardown

```bash
./scripts/99-teardown.sh workloads   # namespaces first, so LBs and NEGs clean up
./scripts/99-teardown.sh infra       # tofu destroy; prompts for the project id
```

KMS keys carry `prevent_destroy`, so a destroy refuses rather than orphaning
anything encrypted with them. Check for orphaned forwarding rules, addresses and
NEGs afterwards — the teardown script prints the commands.
