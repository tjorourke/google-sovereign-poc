# Berlin GCD Google demo: task list

One page, `localhost:8900/google` (demo-console `pages/google-sovereign.html`), with a simple UX. Every item is tested end to end before it is ticked.

Status key: `[ ]` todo · `[~]` in progress · `[x]` done and verified

## 2026-10-01 security and infrastructure audit

- [x] All 12 agents enrolled through programmed enterprise waypoints.
- [x] All 9 MCP Services protected by Strict JWT, audience/expiry checks, and
  JWT subject bound to mesh namespace/ServiceAccount.
- [x] Per-agent/backend EnterpriseAgentgatewayPolicy grants, including the
  corrected tub-sdlc-pm/dev identities and my-payments-2 approval.
- [x] Negative probes: missing/bad JWT, wrong audience, replay from another
  identity, unauthorized tool calls, and direct pod-IP bypass.
- [x] 117/117 live checks; fresh browser wizard → approve → tool call → revoke
  → empty tool list → delete verified with a temporary audit agent.
- [x] Cloud/Helm/load-balancer inventory captured in deploy/inventory.json.
- [x] OpenTofu drift repaired in source; real-profile plan reports no changes.
- [x] Chart manifest and rendered image list match installed versions.
- [x] SDLC console names and Keycloak clients aligned with live tub-sdlc-* agents.
- [x] Gemma tool-call parser failure isolated; runtime upgraded to 0.1.8.

See DEMO-READINESS.md for commands, evidence and remaining limitations. The
sections below retain the earlier feature backlog; a security pass does not
imply the LLM budget/identity work is complete.

## 1. All Solo Enterprise products on latest, with every feature on

| Product | Installed | Latest (2026-10-01) | Script |
|---|---|---|---|
| kagent-enterprise (+crds) | 0.5.9 | 0.5.9 (1.0.0 is alpha) | 40-kagent.sh |
| management (UI, ClickHouse, telemetry) | 0.5.9 | 0.5.9 | 45-telemetry.sh |
| agentregistry-enterprise | 2026.6.1 | 2026.9.0 (blocked, see below) | 50-agentregistry.sh |
| enterprise-agentgateway (+crds) | v2026.9.3 | v2026.9.3 | 70-agentgateway.sh |
| semantic-router (vLLM, not Solo) | 0.3.0 | check | 87-vsr-routes.sh |

- [x] management → 0.5.9 with cost-management + cost-management-writes on (ClickHouse memory request 8Gi)
- [x] kagent → 0.5.9
- [x] agentgateway → v2026.9.3 with budgetDimensions (yaml/cost/budget-dimensions.values.yaml); Demo 1 verified on both routes
- [ ] agentregistry → 2026.9.0: blocked. The 9.0 chart requires an AR license Secret (`enterprise-agentregistry-license`, none exists) and drops `kagent.outboundAuth`, which the AR → kagent deploys use; AR now writes kagent.dev CRDs through RBAC instead. Needs a license and a retest of the trustusbank agent deploys
- [~] Enterprise features on: cost management + writes, budgets, gateway tracing, kagent tracing on; AR → kagent deploys still on 2026.6.1
- [x] Script defaults bumped (45, 70); kagent was already 0.5.9
- [x] VSR SSE buffering fixed (extproc responseBodyMode None)

## 2. TrustUsBank bank website (owned by the Demo 3 agent)
- [ ] A professional static bank site in tjorourke/trustusbank-payments: home, accounts, payments, cards, loans, help
- [ ] Previewed in the Demo 3 panel

## 3. Demo 3 end to end (owned by the Demo 3 agent)
- [ ] PM bot writes the spec, then approve/deny in the console
- [ ] Dev bot opens a PR against the site, then approve/deny
- [x] Both paths tested for real against GitHub (issue #1 → PR #2 → live; issue now closes labelled `live`)
- [x] SDLC agents applied as plain kagent Agents with clean names: tub-sdlc-pm, tub-sdlc-dev (chat verified as bob)

## 4. Every agent has its own identity
- [x] One Keycloak client per agent, with an `agent_id` claim (88-identity.sh)
- [ ] kagent traces name the agent (payments_assistant, …): 0.1.5 image rolling out
- [ ] The agent forwards its token to AGW, so LLM/MCP calls carry the user and agent_id

## 5. Every chat works, signed in as bob
- [ ] The Demo 2 chats answer for all 4 agents (broken by the AGENT_NAME clash; fixed in 0.1.5)
- [ ] The identity strip shows bob
- [ ] The Demo 3 and builder agents chat as bob

## 6. Seeded data visible in AGW (89-cost.sh)
- [x] ClickHouse seed: bob/alice × 4 agents over 7 days (`89-cost.sh seed`; bob $13.64, alice $7.88)
- [x] Live calls priced: Gemma and Gemini added to the model catalog (yaml/cost/model-catalog.yaml via the right-sized parameters); before this every live call cost $0

## 7. A budget in AGW, settable for bob
- [x] budgetDimensions (user, agent, team) from JWT claims: verified, a bob-token call on the models route lands with user=bob, group=payments-ops, agent=trustusbank-console
- [~] JWT auth (Permissive) and entBudgetEnforcement on both the llm and models routes (`89-cost.sh enforce`). Permissive, not Optional: the agents send a non-JWT API-key bearer that Optional rejects. Gaps: the llm route points at a plain Service, so it has no model, tokens or cost (the agents' traffic is invisible to cost and budgets until llm points at an AgentgatewayBackend); the agents do not forward bob's token yet (item 4); and enforcement ignores the seeded ClickHouse spend (bob at a $1 limit still gets 200), so Block only bites on live spend
- [x] EnterpriseAgentgatewayBudget `trustusbank`: bob $12/week Block (about 85% used by the seed), payments-ops $25/week Audit; Accepted and Enforced
- [x] Seen in the UI (kagent.agentic.eu0.internal/age/cost-management, admin-user): $21.53 / 30.1M tokens / 8.8K requests, the trustusbank budget, Dimensions and Virtual Keys. A browser tab opened before the 19:43 UTC UI upgrade needs a hard refresh to see the Cost nav
- [ ] Budget usage bars render empty (ui-backend → cost API on :7777 errors)

## 8. kagent traces complete
- [ ] Demo 2 runs show the agent, LLM and MCP tool spans in the kagent UI

## 9. Agent builder on the page (like the console's /agents)
- [x] Pick a model, skills and MCP tools, then deploy a declarative agent to kagent
- [x] Confetti on deploy
- [x] Chat with it as bob

## 10. MCP tool approval by a platform admin
- [x] An admin reviews an MCP server/tool and approves it (AgentRegistry), as in the earlier demo
- [x] Unapproved tools are not usable by agents

## Final
- [ ] A full click-through of the page, top to bottom
- [ ] Commit (only when asked)
