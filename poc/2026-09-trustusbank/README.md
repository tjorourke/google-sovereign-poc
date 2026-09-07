# TrustUsBank AG — SEPA Instant fraud triage

Multi-agent, MCP-governed financial-crime triage for a fictional German bank,
running on GCD Berlin preview. **Full write-up, diagrams and the zero-trust
assessment: [`docs/trustusbank-sepa-fraud-triage.md`](../../docs/trustusbank-sepa-fraud-triage.md).**

TrustUsBank and its data are invented. GwG, BaFin, the EU Instant Payments
Regulation and the EU consolidated list are real, and are what make the control
boundaries meaningful.

## What it demonstrates

Three declarative agents on a self-hosted model, talking to each other over A2A,
calling two MCP servers through waypoints, with four boundaries enforced by
workload identity rather than by prompt:

- the **fraud desk cannot read customer PII** — it reaches a verdict on a payment
  without being able to see who made it
- **no agent can file** the regulatory report; the chain stops one step short of
  the legal act
- each desk sees **only its own tools**, per identity, not a shared credential
- **only the orchestrator may call either desk over A2A** — any other identity
  gets 403 at the desk's waypoint
- every hop carries a **SPIFFE identity** over mTLS

Each agent deliberately requests a tool it must not have, so the demo proves the
denial rather than the absence of a request.

## Run

```bash
./scripts/deploy.sh     # namespace, MCP servers, agents, policies, A2A edge
./scripts/demo.sh       # the scenario end to end
./scripts/health.sh     # attack every control (expect 23 passed, 0 failed)
```

`./scripts/deploy.sh --ambient` applies only the mesh-enrolment step.

Allow 2-4 minutes for the scenario: three agents and several tool calls on a 3B
model on CPU, because Berlin has no schedulable GPU.

## Prerequisites

`poc/2026-09-agentic-platform/` must be deployed — it provides the cluster, the
ambient mesh, Keycloak, the gateway, TLS, the self-hosted model and o11y. This
lab adds only its own namespace.

## Layout

```
mcp/core_banking.py     account, transactions, customer PII, hold a transfer
mcp/compliance.py       sanctions, PEP, open a case, file a SAR
yaml/00-namespace.yaml  namespace, in the ambient mesh
yaml/05-modelconfig.yaml  self-hosted Qwen2.5-3B via agentgateway
yaml/10-mcp-servers.yaml  both MCP servers as KMCP MCPServer resources
yaml/01-waypoint-params.yaml  pinned Istio cluster id + trust domain for the waypoints
yaml/15-waypoint.yaml   NO resources -- records why one namespace waypoint fails
yaml/20-agents.yaml     the three agents, incl. A2A tool refs
yaml/30-accesspolicies.yaml  tool-level controls (which agent may call which tool)
yaml/35-a2a-accesspolicies.yaml  A2A controls (which agent may call which agent)
yaml/31-waypoint-hop.yaml    workaround for the waypoint hop being refused
yaml/40-a2a-edge.yaml   A2A published through agentgateway
scripts/probe.py        one A2A call, reports the tool-call trace
```

## Waypoints

Four, and each is an enforcement point rather than overhead: two front the MCP
servers for per-tool authz, two front the specialist agents for A2A authz. The
orchestrator has none on purpose — nothing in the mesh calls it.

Read `yaml/15-waypoint.yaml` before trying to reduce that count. One namespace
waypoint looks correct, applies cleanly, and silently loses per-tool
enforcement; and removing an agent's waypoint removes the ability to authorize
who may call it over A2A.
