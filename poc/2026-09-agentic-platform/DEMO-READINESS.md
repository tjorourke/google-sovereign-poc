# Google demo: deployed state and checks

Verified against Berlin on 2026-10-01. Console: <http://localhost:8900/google>.

## Security model

- All 12 kagent Agents have their own programmed enterprise agentgateway waypoint.
- All 9 MCP Services use waypoints: seven in `mcp`, `agents/everything-server`,
  and `kagent/kagent-tools`.
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

Latest security run: **117/117 live checks passed**, plus three offline identity
regressions and 25 existing console tests. Evidence is in
`deploy/security-verification.json`. A fresh `audit-payments` agent was created
through the browser wizard, verified without a grant, approved, used to retrieve
a balance, revoked (empty tool list verified), and deleted. Its successful chat
is captured in `deploy/google-agent-verified.png`.

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
(`vision-demo-2026/demo-console`). Runtime image `trustusbank-agent:0.1.8`
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
- The native MCPServer controller's unauthenticated background discovery of
  `agents/everything-server` is rejected by strict JWT. The calculator uses the
  authenticated RemoteMCPServer `agents/waypoint-tools`; its tool path is tested.
- GCD admission and GPU support are preview-specific. The RAPID version and
  workload allowlists are explicit prerequisites, not a claim about all GDC installs.
