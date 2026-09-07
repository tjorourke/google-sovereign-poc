# TrustUsBank AG — SEPA Instant fraud triage with governed agents

**Status:** running and verified on GCD Berlin preview, 2026-09-07
**Lab:** `poc/2026-09-trustusbank/`
**Depends on:** `poc/2026-09-agentic-platform/` (cluster, ambient mesh, Keycloak, gateway, TLS, o11y)

A worked multi-agent scenario for a fictional German bank, built to answer one
question a regulated buyer always asks: *when an agent touches customer data or
moves money, what stops it, and can you prove it.*

TrustUsBank is invented. The data is invented. The regulatory framing (GwG,
BaFin, the EU Instant Payments Regulation, the EU consolidated sanctions list)
is real, and is what makes the control boundaries land.

---

## The scenario

A SEPA Instant transfer of **EUR 9,850** from `DE89 3704 0044 0532 0130 00` is
held by a velocity rule. It is the fourth transfer to the same new counterparty
in eighteen minutes, totalling EUR 31,400, against a normal weekly outflow of
**EUR 280**. Each amount sits just under the EUR 10,000 reporting threshold —
the pattern is the signal, not any single payment.

The counterparty, *Volkov Trading OOO*, matches the EU consolidated list. Its
controller is a PEP.

The Instant Payments Regulation gives the bank **seconds**, which is what makes
this agentic rather than a batch job.

Three agents split the work along the same lines a real financial-crime desk
does, and — the point of the exercise — along the same lines its **access
control** does.

| Agent | Desk | May call | Deliberately cannot |
|---|---|---|---|
| `payment-triage` | payment triage, orchestrator | `create_case` | `file_sar` |
| `fraud-analysis` | fraud analysis | `get_account`, `list_transactions` | `get_customer` |
| `sanctions-screening` | sanctions screening | `screen_sanctions`, `check_pep` | anything on core-banking |

---

## Who talks to what

```mermaid
flowchart TB
  caller["Partner / group system<br/>(external A2A caller)"]

  subgraph edge["agentgateway (edge)"]
    gw["Gateway agentgateway-proxy<br/>TLS terminated, 5 SANs"]
  end

  subgraph tub["namespace trustusbank — Istio ambient, mTLS"]
    triage["payment-triage<br/>orchestrator"]
    subgraph wa1["waypoint: A2A authz"]
      fraud["fraud-analysis<br/>fraud desk"]
    end
    subgraph wa2["waypoint: A2A authz"]
      sanc["sanctions-screening<br/>sanctions desk"]
    end

    subgraph wp1["waypoint: core-banking"]
      cb["MCP core-banking<br/>get_account, list_transactions,<br/>get_customer, flag_transaction"]
    end
    subgraph wp2["waypoint: compliance"]
      cp["MCP compliance<br/>screen_sanctions, check_pep,<br/>create_case, file_sar"]
    end
  end

  model["self-hosted Qwen2.5-3B<br/>llm.agentic.eu0.internal"]

  caller -->|"A2A over HTTPS"| gw
  gw -->|"a2a backend"| triage
  triage -->|"A2A, only permitted caller"| fraud
  triage -->|"A2A, only permitted caller"| sanc
  triage -->|"MCP"| cp
  fraud -->|"MCP"| cb
  sanc -->|"MCP"| cp
  triage -.->|"OpenAI API via gateway"| model
  fraud -.->|"inference"| model
  sanc -.->|"inference"| model
```

**A2A** carries agent-to-agent delegation: the orchestrator to each specialist,
and the external caller to the orchestrator. **MCP** carries every tool call.
Both specialists reach their tools through a waypoint, never directly.

Agent-to-agent is declared, not coded — `tools[].type: Agent` with a Kubernetes
reference. kagent resolves it to the target agent's A2A endpoint and surfaces it
to the model as a callable tool named `trustusbank__NS__fraud-analysis`.

---

## The flow

```mermaid
sequenceDiagram
  autonumber
  participant C as External caller
  participant G as agentgateway (edge)
  participant T as payment-triage
  participant F as fraud-analysis
  participant S as sanctions-screening
  participant WB as waypoint core-banking
  participant WC as waypoint compliance

  C->>G: A2A message/send (HTTPS)
  G->>T: a2a backend, L4 restricted to gateway identity
  T->>F: A2A "Assess IBAN DE89…"
  Note over F: only payment-triage may call this desk<br/>any other identity gets 403 at its waypoint
  F->>WB: MCP tools/list
  WB-->>F: get_account, list_transactions only
  Note over WB: get_customer removed by AccessPolicy<br/>fraud desk never sees PII
  F->>WB: tools/call list_transactions
  WB-->>F: 4 transfers, EUR 31,400, Volkov Trading OOO
  F-->>T: VERDICT ANOMALOUS
  T->>S: A2A "Screen Volkov Trading OOO"
  S->>WC: tools/call screen_sanctions + check_pep
  WC-->>S: EU-2024-0412 match, controller is PEP
  S-->>T: VERDICT BLOCK
  T->>WC: tools/call create_case (severity HIGH)
  WC-->>T: CASE-4108
  T->>WC: tools/call file_sar
  WC--xT: not available to any agent
  Note over T,WC: chain stops short of the legal act
  T-->>C: FRAUD ANOMALOUS / SANCTIONS BLOCK / CASE-4108 / HANDOVER
```

Verified output from `./scripts/demo.sh`:

```
Tools invoked: trustusbank__NS__fraud_analysis,
               trustusbank__NS__sanctions_screening, create_case
Outcome:       CASE: CASE-4112
               HANDOVER: filing a report is reserved to a compliance officer
```

The two `trustusbank__NS__*` entries are the A2A delegations: kagent resolves a
`tools[].type: Agent` reference to the target agent's A2A endpoint and surfaces
it to the model as a callable tool.

**The model is the non-deterministic part, and that is the point.** Across runs
on the self-hosted 3B model this chain varies: it usually calls both desks and
`create_case`, but one observed run delegated to both desks and then *invented* a
case identifier (`2023-09-15-VolkovTradingOOO`) instead of calling the tool, and
mislabelled a verdict. Another produced the full four-line summary; another
truncated it.

None of that variance touches the security properties. The model chooses what to
attempt; the waypoints decide what succeeds. A run where the model behaves and a
run where it improvises produce the same answer to "could the fraud desk read
customer PII" — no — because that is settled by an AccessPolicy and not by the
model's cooperation. A demo whose guarantees depended on a 3B model following a
four-step plan would not be worth showing a bank; this one does not.

If you want the narrative crisper for a live audience, a larger model makes the
prose better and the tool calls more reliable. It does not make the controls any
stronger, and it costs latency on CPU — there is no schedulable GPU in Berlin.

---

## The four controls, and how each was proved

Every agent **deliberately requests a tool it must not have**. If the agent spec
simply omitted them, the demo would prove only that we can write a short list.
Listing them and having policy remove them proves the boundary is enforced by
workload identity, and that no prompt wording talks its way past it.

Each denial is paired with a positive control on the same server, so a pass
cannot be an unreachable waypoint quietly reading as good news. Verification is
by **tool-call trace**, never by asking the model what it can do — a 3B model
recites tool names from its own configuration whether or not they are reachable,
which looks exactly like a policy failure.

`./scripts/health.sh` — **23 passed, 0 failed**.

| # | Control | Attempt | Result |
|---|---|---|---|
| 1 | **PII boundary** | fraud desk asked for name + date of birth | called `get_account`/`list_transactions`, never `get_customer`; no PII in the answer |
| 2 | **Separation of duties** | orchestrator told to file to the FIU | could not call `file_sar`; `create_case` still worked |
| 3 | **Tool scoping per identity** | sanctions desk asked for transactions | no tool call at all; `screen_sanctions` still worked |
| 4 | **A2A authorization** | sanctions desk called the fraud desk directly | **HTTP 403**; the orchestrator got 200 on the same endpoint |
| 5 | **Attributable identity** | — | all three agents ztunnel-captured with SPIFFE identities; only the gateway and kagent may open the orchestrator's A2A port |

Control 1 is the one worth showing an executive: **the fraud desk reaches a
verdict on a payment without ever being able to see who made it.** That is data
minimisation as a mechanism rather than a policy document.

This is not merely discovery filtering. Calling the MCP server **directly** from
the fraud desk's own pod, bypassing the agent's tool list entirely:

```
tools/list              -> ['get_account', 'list_transactions']
tools/call get_customer -> HTTP 400
```

The waypoint filters by caller identity, so a compromised or reprogrammed agent
gets the same answer as a cooperative one.

---

## Zero trust: what this build actually has

| Property | Status | Mechanism |
|---|---|---|
| No implicit network trust | **yes** | Istio ambient; ztunnel mediates every hop |
| Workload identity on every hop | **yes** | SPIFFE via ztunnel, `spiffe://cluster.local/ns/trustusbank/sa/<agent>` |
| Encrypted in transit, internal | **yes** | mTLS between all captured pods |
| Encrypted in transit, edge | **yes** | TLS on all five browser-facing hostnames, private CA via cert-manager |
| Authorization at L4 by identity | **yes** | Istio `AuthorizationPolicy`, incl. who may open the A2A port |
| Waypoint identity params pinned | **yes** | cluster id and trust domain set explicitly, not defaulted |
| Authorization at L7 per tool | **yes** | `AccessPolicy` → per-tool at the waypoint |
| Least privilege per agent | **yes** | three distinct AccessPolicies, allow-list semantics |
| Human identity on the tool call | **no** | see OBO below |
| Authorization on the A2A hop | **yes** | `AccessPolicy` `targetRef.kind: Agent`, enforced at the target's waypoint (403 verified) |
| Per-A2A-*method* authorization | **no** | no `backend.a2a` in `AgentgatewayPolicy`; per-caller only, not per JSON-RPC method |
| Central audit of agent actions | **partial** | Prometheus with `source_principal` attribution; no immutable audit store |

Two honest gaps, both worth naming to a customer before they find them.

### 1. On-behalf-of / RFC 8693 — supported by the stack, not used here

We authorize by **workload** identity. The AccessPolicy subject is
`kind: Agent`, so the audit trail says *the fraud desk agent read the
transactions* — not *it read them on behalf of officer Schmidt*. For GwG and
DORA evidencing, attribution to a **person** is usually what is being asked for.

The capability is present and does not need building:

**agentgateway** implements OAuth 2.0 Token Exchange in
`AgentgatewayPolicy.spec.backend.auth.oauthTokenExchange`, with the full RFC 8693
surface — `subjectToken`, `actorToken` (including `mayAct: Required`),
`grantType`, `requestedTokenType`, `audiences`, `scopes`, `resources`, and
`clientAuth` up to `privateKeyJwt`. Also present: `crossAppAccess` and
`jwtSign`.

**kagent-enterprise** AccessPolicy can authorize on the delegation claim
directly. Instead of `kind: Agent`, a subject can be a user group evaluated
against the STS-issued token:

```yaml
from:
  subjects:
    - kind: UserGroup
      name: fraud-officers
      userGroup:
        issuer: "<STS issuer>"
        claimName: "act.sub"        # RFC 8693 actor claim
        claimValue: "<agent identity>"
        jwksKey:
          inline: '<jwks>'
```

`claimName: act.sub` is the RFC 8693 `act` claim: it authorizes on *who the
agent is acting for* plus *which agent is acting*. Upstream ships e2e coverage
for it at `kagent-enterprise/test/e2e/obo/`, and the `userGroup` fields are
present in the CRD installed on this cluster.

**Recommended next step.** Move these three AccessPolicies from `kind: Agent` to
`kind: UserGroup` on `act.sub`, with Keycloak as the STS and token exchange
configured on the gateway. The controls stay the same; the audit trail gains the
human. Until then, do not tell a bank that tool calls are attributable to a
named officer — they are attributable to a named *agent*.

### 2. A2A authorization: by identity yes, by method no

Agent-to-agent calls **are** authorized, and by the same primitive as tools —
`AccessPolicy` with `targetRef.kind: Agent`, enforced at the **target agent's**
waypoint:

```yaml
spec:
  action: ALLOW                    # DENY is also supported
  from:
    subjects:
      - kind: Agent
        name: payment-triage
        namespace: trustusbank
  targetRef:
    kind: Agent                    # an AGENT, not an MCPServer
    name: fraud-analysis
```

Allow-list semantics again: naming the orchestrator as the only permitted caller
refuses every other identity in the cluster — another agent, a rogue pod, a curl
from a neighbouring namespace. Verified with the same endpoint and two caller
identities:

| Caller | Result |
|---|---|
| `sanctions-screening` → `fraud-analysis` | **HTTP 403 Forbidden** |
| `payment-triage` → `fraud-analysis` | **HTTP 200** |

That is the answer to "which systems can ask my fraud desk a question", which is
a real audit question, rather than a network diagram asserting it.

The subject can also be a `UserGroup` evaluated against JWT claims (`issuer`,
`audiences`, `claimName`, `claimValue`, `jwksKey`), so the A2A hop can be gated
on an end-user token instead of a workload identity — the same hook that carries
the RFC 8693 `act.sub` claim described above.

**What genuinely does not exist is per-A2A-METHOD authorization.**
`AgentgatewayPolicy.spec.backend` exposes `mcp.{authentication,authorization}`
but has no `a2a` equivalent, so a raw agentgateway policy cannot allow
`message/send` while denying `tasks/cancel`. A2A is authorized per caller and
per target agent, not per JSON-RPC method, where MCP is authorized per tool.
Narrowing that asymmetry is the useful feedback item; the coarse claim that "A2A
is ungoverned" is wrong and was corrected here after testing it.

## Two implementation findings

**Every waypoint is an enforcement point — place them by what needs enforcing.**
The instinct is to minimise waypoints, and it is half right. There are two
distinct jobs:

- a waypoint fronting an **MCPServer** enforces per-tool `AccessPolicy`
- a waypoint fronting an **Agent** enforces per-caller A2A `AccessPolicy`

So this namespace runs **four**, and each one earns its pod: `core-banking` and
`compliance` for tool scoping, `fraud-analysis` and `sanctions-screening` for A2A
authz. The orchestrator has none, deliberately: nothing inside the mesh calls
it, its inbound is the external caller arriving through agentgateway, and an L4
`AuthorizationPolicy` already restricts which identities may open its A2A port.
A waypoint there would add a pod and enforce nothing new. Add the label if you
later want JWT or `UserGroup` authz on its inbound.

An earlier revision of this lab removed the agent waypoints on the reasoning
that they "buy observability rather than policy". That was wrong — they are the
A2A authorization enforcement point — and it is recorded here because the
mistake is easy to repeat and the resulting stack looks identical.

**One namespace waypoint does not work, and fails silently.** The obvious
optimisation — a single Gateway plus `istio.io/use-waypoint` on the namespace —
applies cleanly and loses per-tool enforcement without an error. The cause is in
`kmcp-enterprise/.../translator/waypoint.go`: the `kagent.solo.io/waypoint`
label does three things, not one. It creates the Gateway (name derived as
`<kind>-<name>-waypoint`, not configurable), sets `istio.io/use-waypoint` on the
Service, **and sets `appProtocol: kgateway.dev/mcp`** on the service port — that
last one is what makes the waypoint MCP-aware. Removing the label runs
`cleanupWaypointResources()`, which deletes the Gateway and strips the
`use-waypoint` label, and the appProtocol is never applied. There is no spec
field to reference a pre-existing waypoint, so a shared waypoint is not
currently expressible. That is the second feedback item: **let an MCPServer or
Agent name an existing waypoint**, so a namespace can share one.

On Autopilot the pod count is not free — each waypoint is a real reservation
against the 24 vCPU C3_CPUS quota, and five of them only scheduled after the
cluster added a node.

**The Istio identity parameters are pinned, and the network is deliberately
not.** kagent-enterprise's `_docs/platform/agw-waypoint-params.md` documents
three parameters for the waypoint GatewayClass and warns that if the waypoint's
view of them is wrong, "ztunnel bypasses the waypoint entirely and
`AccessPolicy` enforcement is silently skipped". A control whose failure mode is
silent must not rest on a default, so `istioClusterId: Kubernetes` and
`ca.trustDomain: cluster.local` are now set explicitly in an
`EnterpriseAgentgatewayParameters` attached to the GatewayClass, even though both
match the Istio defaults here.

`istioNetwork` is left unset on purpose, and the reasoning matters:

- The parameter must **match** `topology.istio.io/network` on `istio-system`. On
  this cluster that label is empty, istiod has no network env and neither does
  ztunnel — a consistent single, unnamed network. Setting the parameter to a
  name the mesh does not know would create the very mismatch the doc warns
  about.
- Naming the network consistently means setting `global.network`, which adds
  `ISTIO_META_NETWORK` to **ztunnel's pod spec**. On Autopilot the
  `WorkloadAllowlist` pins that spec including `env`, so ztunnel would be
  refused admission and the mesh would drop until the allowlists are regenerated
  and reinstalled (phases 62 and 63 of the platform lab).
- It would buy nothing today. A named network matters for multi-network and
  multi-cluster routing, and Berlin has no Fleet, no GKE Hub and no multi-cluster
  services — there is no second network to route to.
- Enforcement is **verified working** with it unset: an unauthorised A2A caller
  gets 403 at the waypoint, and a denied tool gets a filtered `tools/list` plus a
  400 on direct invocation. The waypoint is demonstrably in the path.

If this cluster ever joins a second network, the order is: regenerate the
allowlists for the new ztunnel spec, install them, set `global.network` on istiod
and ztunnel, label `istio-system`, then add `istioNetwork` to match. Doing it in
any other order takes the mesh down.

---

## Running it

```bash
cd poc/2026-09-trustusbank
./scripts/deploy.sh     # namespace, MCP servers, agents, policies, A2A edge
./scripts/demo.sh       # the scenario, end to end
./scripts/health.sh     # try to break all four controls (expect 17/0)
```

`./scripts/deploy.sh --ambient` applies only the mesh-enrolment step, which also
brings `agentregistry-system` and `mcp` into ambient — before that change the
AgentRegistry-deployed agent was the one workload in the stack with neither a
gateway policy nor an mTLS identity.

Allow two to four minutes for the scenario: three agents and several tool calls
on a 3B model on CPU. There is no schedulable GPU in Berlin
(`feedback/google/12`), so in-boundary inference is CPU-bound by construction.

## Customer Value

The problem: an agent that can reach a core banking system can, by default,
reach all of it — and an auditor cannot tell which flows happened or why they
were permitted. The benefit here is specific and demonstrable: a fraud
assessment completed with **zero** access to customer personal data, a
regulatory filing that remains impossible for any agent to submit, and every hop
carrying a cryptographic identity. The differentiator is that all of it is
declarative and enforced outside the agent — a competitor's answer to "stop the
agent reading PII" is a sentence in a system prompt, which the next model
revision may ignore.

**Worth noting:** the honest limit is human attribution. Today the trail names
the agent, not the officer. RFC 8693 token exchange closes that and is already
in the product — it is configuration, not roadmap, and it should be the next
thing built on this lab.
