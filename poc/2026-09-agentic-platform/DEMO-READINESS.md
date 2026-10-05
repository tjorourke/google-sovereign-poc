# Google demo: deployed state and checks

Verified against Berlin on 2026-10-01. Console: <http://localhost:8900/google>.

## 2026-10-02: DLP, PDF summary, and AGW audit

**Hosted console:** the Google demo now also runs in Berlin at
`https://agw.agentic.eu0.internal/google` (sign in: `solo` / `S010g00g13!`).
A styled login page issues an HMAC-signed 12h session cookie; `Sign out` clears
it. Unauthenticated pages redirect to `/login`, APIs answer 401, wrong
credentials 401, and cross-origin writes are refused. Verified live through the
gateway: login/logout, hub, routing chat on Gemma, DLP page + upload cards with
trace links, builder and approvals APIs, and the staging/prod site preview — all
served from the cluster, with no laptop port-forwards.
Source and deployer: `console/` and `scripts/97-google-console.sh` in this repo.
The laptop console in `solo-demos/vision-demo-2026/demo-console` is unchanged
by this and keeps working on localhost:8900.

Builder fix verified live on the hosted page: the wizard's name generator used
to produce suffixes longer than the server's 12-character cap (e.g.
`trustusbank-my-payments-2`, rejected with the cryptic NAME_RE error). It now
compares names against the full deployed names and keeps generated suffixes
within the cap (`my-payment-2`), and the server's error names the actual
problem. Verified: template → wizard → Deploy to kagent → agent Ready, then
deleted. The same pre-existing bug remains in the laptop console's
google_builder.py/agents.js; port if wanted.
Website staging uses immutable commit-pinned source snapshots on the existing
Python runtime (no laptop Docker); a runtime/Dockerfile change is refused rather
than silently skipped.

Native Desktop follow-up: its real request contained 19,321 input tokens plus
2,048 output tokens, exceeding the previous 8,192-token vLLM setting. Gemma is
now serving a 24,576-token context. A regression with 19,605 input tokens plus
the mortgage PDF returned a masked summary. Oversized requests now retain the
actual context-limit message as HTTP 400 instead of becoming an AGW parser 502.
The DLP log panel has a persistent **Clear history** action; AGW audit traces
remain available. All 28 console tests (including three history-reset tests)
pass.

Presenter steps and deployment commands:
[`docs/trustusbank-dlp-audit.md`](../../docs/trustusbank-dlp-audit.md).

- `96-dlp.sh` deploys the mirrored Presidio image and TrustUsBank policies.
  Live probes verified injection → 403, customer data with Gemini requested →
  masked Gemma call, clean prompt → Gemini, and upload → Gemma summary.
  The strengthened probe verifies masking against its own trace ID and sends
  spoofed classification headers. Six additional negative controls passed via
  `verify_dlp_edges.py`; all 25 existing console unit tests pass.
- Browser upload of the generated `deploy/trustusbank-case.pdf` returned a
  Gemma summary with placeholders in 5.38 seconds. Files are extracted inside
  the cluster. The response includes a direct AGW trace link.
- Claude Desktop's EKS-style reader/conversion path is also deployed at
  `https://agw.agentic.eu0.internal/trustusbank`. Five live protocol checks pass:
  invalid JWT, token counting, Messages, PDF/SSE and 403 rejection. The DLP page
  displays external calls with a Claude Desktop label and attachment filenames.
  `claude_desktop_berlin.py on` switches the local Mac profile (administrator
  password required); native Desktop app testing remains a local step.
- A name-only prompt that CEL misses is stopped by Presidio with 409 before
  Gemini inference. The DLP console retries on Gemma; this was browser-verified.
- Gateway traces now carry `audit.user`, `audit.agent`, `audit.team` and signed
  subject from the verified JWT. Bob / trustusbank-console / payments-ops was
  verified in AGW Span Attributes. The table's User ID column remains N/A in
  this installed UI version; use Span Attributes → audit.
- `94-audit-waypoints.py --apply` installed Accepted/Attached tracing policies
  on all 15 enterprise waypoints. A real payments-agent request showed the
  kagent invocation, both model calls and `get_account_balance` in one AGW trace.
  MCP identity remains the verified workload JWT + SPIFFE identity, not a
  delegated Bob token.
- `/google` has a collapsed architecture expander with external laptops,
  AGW/kagent/DLP/models, and a clearly marked planned Agentdesktop fleet.
- Cluster deployment and sample-generation sources are in this repository;
  console handlers/pages are in the companion repository. No fleet deployment
  was added. DLP is scoped to the `models` route, not the agents' `llm` route.

After a rebuild run `bash ../../scripts/deploy-google-demo.sh` from this lab.
After adding an agent re-run `94-audit-waypoints.py --apply`. A re-run of
`87-vsr-routes.sh` preserves installed DLP route rules.

## Security model

- All 9 kagent Agents have their own programmed enterprise agentgateway waypoint.
- All 7 MCP Services use waypoints: six in `mcp` and `kagent/kagent-tools`.
- Every MCP route uses `jwtAuthentication.mode: Strict`, the cluster's signed
  public JWKS, audience `trustusbank-mcp`, and required `sub`/`exp` claims.
- JWT subject must equal `system:serviceaccount:<mesh namespace>:<mesh SA>`.
  Invalid/missing tokens and wrong audience return 401; identity replay returns 403.
- Each agent/backend has an explicit `EnterpriseAgentgatewayPolicy` tool grant.
  The fixed grants live in `yaml/mcp-mesh/grants.json`; builder approvals live in
  AgentRegistry. Each reconciler prunes only its own policies.
- Direct pod-IP calls are blocked at ztunnel. No MCP edge HTTPRoutes remain.
- `mcp-catalog` and `kagent-controller` have list-only discovery grants. Controller
  discovery headers are refreshed from a rotating projected JWT every minute.
- Python ADK agents use the mounted `sitecustomize.py` adapter, which installs
  ADK's HTTP-client-factory extension. It reads a projected token on every MCP
  request and refuses cross-origin redirects. It does not attach this token to
  model requests. Changing the adapter hash rolls agents automatically.

Keycloak identifies bob on A2A requests. Kubernetes JWT + SPIFFE identifies the
agent on MCP requests. These are separate identities and trust boundaries.

## Repeat before presenting

From this directory:

```bash
export GCD_KUBECONFIG="$PWD/deploy/console.kubeconfig"
export KUBECONFIG="$GCD_KUBECONFIG"
export KUBE_CONTEXT=berlin-console
bash scripts/92-mcp-lockdown.sh --verify
python3 scripts/verify_mcp_security.py
python3 scripts/capture_infrastructure.py
```

To reconcile the full deployment, omit `--verify`. Run again after adding an
MCP server, changing an agent, rotating the cluster JWT signing key, or rebuilding
the cluster. The console reconciles builder workloads after deployment and on
the deployment-status poll. Unknown MCP servers must be added to the inventory
and granted explicitly before use.

Latest security run: **89/89 live checks passed** (2026-10-02, after the
sum-demo removal; the earlier 117/117 run predates it and included the calc
checks). Evidence is in `deploy/security-verification.json`. A fresh
`audit-payments` agent was created through the browser wizard, verified without
a grant, approved, used to retrieve a balance, revoked (empty tool list
verified), and deleted. Its successful chat is captured in
`deploy/google-agent-verified.png`.

The JWKS in the policy is public key material read from the cluster API. It is
not an embedded signing key. Tokens, client secrets, licenses and kubeconfigs
must never be committed. The console kubeconfig is a local administrative demo
credential created by `91-console-kubeconfig.sh`.

## Installed versions

| Component | Verified version |
|---|---|
| GKE Autopilot | 1.36.0-gke.4681000, RAPID |
| Solo Istio base / istiod / CNI / ztunnel | 1.30.4-solo |
| kagent Enterprise and CRDs | 0.5.9 |
| Solo management | 0.5.9 |
| Enterprise agentgateway and CRDs | v2026.9.3 |
| AgentRegistry Enterprise | 2026.6.1 |
| Semantic router | 0.3.0 |
| cert-manager | v1.16.2 |
| External Secrets | 0.10.5 |
| kube-prometheus-stack | 65.5.1 |
| TrustUsBank bank/builder/SDLC agent runtime | 0.1.8, kagent-adk 0.10.0-rc5 |

The runtime requests complete Gemma tool responses before parsing them. The
older vLLM pythonic streaming parser could terminate a turn without returning a
tool call. A2A still streams tool events and the final answer. AST parsing accepts
only literal keyword arguments; it never evaluates generated Python.

AgentRegistry 2026.9.0 is a pending migration, not the installed version. It
requires its own license Secret and changes the AR-to-kagent deployment API.
`50-agentregistry.sh` and `infra/helm/charts.txt` remain on the working version.

## Infrastructure and load balancers

Source of truth: `../../infra/tofu/profiles/gcd-autopilot.tfvars` and the Helm
install scripts. `deploy/inventory.json` is the dated live evidence, including
images/resources, PVCs, DNS, Cloud SQL, Cloud NAT, routing, and security policies.
It deliberately excludes Secrets, Helm values, environment values and raw state.

OpenTofu was checked with the real profile and reports **no changes**. The
profile now retains the Istio privileged-admission paths and the five existing
Workload Identity bindings. Earlier defaults would have removed both.

| Kubernetes LoadBalancer | Address | Exposed ports |
|---|---|---|
| agentgateway-system/agentgateway-proxy | 10.20.15.217 (internal) | 80, 443 |
| agentgateway-system/agentgateway-proxy-external | 34.3.138.211 | 80, 443 |
| keycloak/keycloak-external | 34.3.138.239 | 80 |
| solo-enterprise/solo-enterprise-telemetry-gateway | 34.3.133.53 | 4316, 4317 |
| solo-enterprise/solo-enterprise-tunnel | 34.3.134.17 | 9000 |
| solo-enterprise/solo-enterprise-ui | 34.3.137.152 | 80, 8091 |

Cloud SQL uses private PSC at `10.20.0.44`; private nodes egress through Cloud
NAT (`34.3.143.120` at capture time). LBs are Kubernetes-managed passthrough
load balancers, not a deployed Cloud Armor regional ALB. `85-edge.sh` is an
optional alternative; do not describe it as active in this demo.

## Console and source ownership

The running console is in `solo-demos/vision-demo-2026/demo-console`, not this
repository. Its Google modules import this repo's policy renderer and reconciler.
The bank runtime and deployment sources live under its `trustusbank/` and
`trustusbank-sdlc/` directories. Changes in both repositories must be committed
for the complete demo to be reproducible.

Companion source commit: `ecd2ec4c` in `tjorourke/solo`
(`vision-demo-2026/demo-console`). Runtime image `trustusbank-agent:0.1.10`
has manifest digest `sha256:f25dbcac4a89a81fc9f826289731f3593de43d9588d4007ee4a8aefa397a5807`.

Pages: `/google`, `/google/routing`, `/google/agents`, `/google/agents?new=1`,
`/google/approvals`, `/google/sdlc`. Cost links to the Enterprise UI.

## Remaining product/demo limitations

- LLM JWT policies are Permissive, separate from strict MCP authentication.
  Agents still use the existing model API-key placeholder. Per-user live LLM
  budget enforcement is not established merely by strict MCP identity.
- Seeded cost data is marked `seed-*`; it is illustrative history. Seeded spend
  does not demonstrate live budget enforcement. The existing `llm` route targets
  a Service, so its spans do not carry AI token pricing like the `models` route.
- GCD admission and GPU support are preview-specific. The RAPID version and
  workload allowlists are explicit prerequisites, not a claim about all GDC installs.

## 2026-10-02: sum/calculator demo removed

The `everything-server` MCP toy and its three agents (`trustusbank-sovereign`,
`-sovereign-calc`, `-waypoint-calc`) were the platform-validation demo, and the
user-facing demo does not use them. Removed from the cluster (agents, AR
deployment record, both everything-server deployments and Services, routes,
backends, policies, waypoints; the `agents` namespace) and from the repo: phases
90/56/67/69/95 left the default chain (18 phases now), `verify_mcp_security.py`
lost its two calc checks and its declarative fallback, and
`mcp_security.py`/`68-agent-mesh-policies.sh`/`lib.sh`/`92-mcp-lockdown.sh` no
longer reference them. After cleanup: **89/89 security checks passed** (a probe
run during the policy re-render reported one transient empty tool list; the
clean re-run is the number to quote). The waypoint/JWT/grant story is unchanged
— the bank and SDLC agents already carry it.
