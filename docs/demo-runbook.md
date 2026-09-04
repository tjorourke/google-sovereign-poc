# Demo runbook: Solo agentic platform on Google Cloud Dedicated (Berlin)

**The story in one sentence:** AgentRegistry publishes and deploys the agent,
agentgateway governs which tools it may call, and Istio ambient governs which
workloads may talk to each other at all. All three run inside a sovereign cloud
that, until 2026-09-04, could not run a service mesh of any kind.

Verified working 2026-09-03 21:00 UTC:

| | |
|---|---|
| Enterprise UI | <http://34.3.139.105> HTTP 200 from a laptop |
| Keycloak login | `34.3.137.194`, needs one hosts entry (step 1) |
| Gateway, external | `34.3.140.230` fronts the same HTTPRoutes as the internal LB |
| Hand-written agent | `sovereign-calc` in `kagent`, 1/1 |
| Registry-deployed agent | `sovereignagent` in `agentregistry-system`, 1/1, pushed by AgentRegistry |
| Model | Qwen2.5-3B-Instruct on CPU, in-cluster, 1/1 |
| Gateway data plane | 3 pods, 3 nodes, 3 zones, behind a PDB |
| MCP tool invocation | proven by nonce, and visible in the trace tree |
| Tracing | working. It is the strongest thing you can put on screen. |

There are two agents on purpose. `sovereign-calc` was written by hand with
`kubectl`. `sovereignagent` was built from a scaffold, catalogued, and then
deployed into the cluster **by AgentRegistry**, with no kubectl at any point.
Showing both is what makes the governance argument land: the same gateway policy
governs both, whoever created them.

---

# PART 1

## Step 1: add the hosts entry

Keycloak's hostname lives in a private DNS zone and GCD has no public zone, so
your browser can never resolve it. One line, one time.

```bash
sudo sh -c 'echo "34.3.137.194  keycloak.agentic.eu0.internal" >> /etc/hosts'
```

Check it:

```bash
curl -s http://keycloak.agentic.eu0.internal/realms/agentregistry/.well-known/openid-configuration \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'
```

You want `http://keycloak.agentic.eu0.internal/realms/agentregistry`.

If you get an HTML block page mentioning phishing, that is your laptop's
endpoint protection intercepting a plaintext HTTP login page, not a platform
fault. Nothing in the demo depends on your laptop minting tokens: the scripts
mint inside the cluster for exactly this reason. See step 5.

## Step 2: log in to the UI once, tonight

Open <http://34.3.139.105>, log in as `admin-user` / `password`. Confirm three
things and then close it:

1. The **Agents** tab lists `sovereign-calc` and `sovereignagent`.
2. The **Tracing** tab loads and shows rows.
3. Clicking a trace opens a tree with named spans.

If any of this fails tonight, you still have a complete demo from the terminal.
Do not try to fix it on the call.

## Step 3: know the re-auth command

Sessions expire roughly every 45 minutes and there is no service-account path
for a human principal here. This is the single most likely thing to interrupt
you.

```bash
cd ~/code/google-sov && ./scripts/gcd-auth.sh
```

Two browser flows. **A 404 page is the correct outcome.** If you see
`invalid_grant: Refresh token has expired`, or a `gke-gcloud-auth-plugin`
error on any kubectl command, that is what it means. Run it and carry on.

---

# PART 2: DO THIS 10 MINUTES BEFORE THE CALL

> **One directory for everything from here on.** Every command in Part 2 and
> Part 3 runs from `~/code/google-sov/poc/2026-09-agentic-platform`. If a command
> ever says "No such file or directory", you are in the wrong directory. `cd`
> back to that one and re-run. Nothing later asks you to move.

## Step 4: authenticate and get cluster credentials

```bash
cd ~/code/google-sov/poc/2026-09-agentic-platform
../../scripts/gcd-auth.sh
gcloud container clusters get-credentials agentic \
  --location u-germany-northeast1 --project 'eu0:soloio-eval'
```

## Step 5: connect arctl

`arctl` talks to AgentRegistry, which has no public address, and it needs a
token whose issuer AgentRegistry recognises. This script does both: it mints the
token inside the cluster and opens a port-forward.

```bash
source scripts/55-arctl-connect.sh
arctl get runtimes
```

You want three runtimes listed. **Source it, never pipe it** — `source ... | tail`
runs in a subshell, silently loses the token, and the next `arctl` call returns
`401 Unauthorized`.

Keep this shell for the whole demo: the port-forward and the token live in it.
If the session expires mid-demo, re-run step 4 and then this step.

## Step 6: check health

```bash
kubectl get pods -A | grep -vE 'kube-system|gke-managed|gmp-|Completed'
```

Running in: `keycloak`, `kagent`, `agentregistry-system`, `agentgateway-system`,
`solo-enterprise`, `model`, `mcp`.

## Step 7: warm the model up and seed a trace, off-screen

CPU inference. The first response takes 20 to 60 seconds and later ones are
quicker. This also puts a trace in the Tracing tab so the tab is never empty
when you open it.

```bash
./scripts/57-ar-ask.sh "Add 2 and 3 using your sum tool."
```

Do this twice. The second run is the one that shows how it will feel live.

## Step 8: confirm the policy is in its starting state

```bash
kubectl -n kagent get remotemcpserver everything-server \
  -o jsonpath='{.status.discoveredTools[*].name}'; echo
kubectl -n agentregistry-system get remotemcpserver -o name | grep sovereign-tools
```

Expect `reverse_text sum`. If not, run the reset block at the end of this file.

## Step 9: open two windows

- Browser at <http://34.3.139.105>, already logged in, on the **Agents** tab.
- Terminal in `~/code/google-sov/poc/2026-09-agentic-platform`, font size up,
  with step 5 already sourced.

---

# PART 3: THE DEMO

Six to twelve minutes. **Acts 1 and 2 are the demo.** Acts 3 to 5 are there if
the audience is technical and you have time.

Open with one sentence rather than a terminal: *this is Solo's agentic platform
running in Google's German sovereign cloud, with the model hosted inside the
boundary. What I want to show you is who decides what an agent is allowed to
do.* Then go straight to Act 1.

## Act 1: the registry deploys the agent (4 min, terminal)

This is the act that is new, and it is the one a governance buyer cares about.

### The catalogue is the control point

```bash
arctl get mcpservers
arctl get agents
arctl get runtimes
```

Say: *this is the approved inventory. Not a wiki page describing what teams are
allowed to run, an actual registry, and it is the thing that does the deploying.
Note where the tool server's URL points: at agentgateway, not at the tool server
itself. Anything the catalogue hands out is governed by construction.*

```bash
arctl get mcpserver sovereign-tools -o yaml | grep -A3 remote:
```

### Push the agent into the cluster

```bash
arctl apply -f agentregistry/catalog/deployment.yaml
arctl get deployments
```

Then watch what appeared, in the cluster, created by the registry:

```bash
kubectl get agents.kagent.dev -A
kubectl get remotemcpservers.kagent.dev -A | grep sovereign-tools
kubectl -n agentregistry-system get deploy,pods | grep sovereignagent
```

Say: *I did not run kubectl to create any of that. AgentRegistry resolved the
catalogued agent and its approved tool server, then created the kagent Agent,
the tool binding and the workload itself, under its own identity. The
separation matters to an auditor: a developer publishes to the catalogue, and
the platform decides what reaches a cluster.*

**If asked what is actually in the image:** the agent image carries no model
endpoint, no key and no tool URL. Show it:

```bash
kubectl -n agentregistry-system get deploy \
  -o jsonpath='{.items[?(@.metadata.name!="")].spec.template.spec.containers[0].env[*].name}' \
  | tr ' ' '\n' | grep -E 'OPENAI|MCP_SERVERS|OTEL_EXPORTER' | sort -u
```

Say: *the model endpoint, the tool config and the tracing endpoint are all
injected at deploy time by the registry. That is what makes the same image
portable to another runtime without a rebuild, and it is why there is no
credential in the artifact.*

### Ask it something that needs the tool

```bash
./scripts/57-ar-ask.sh "Add 17 and 25 using your sum tool."
```

You get the tool call and the answer:

```
Tools the agent called:
  1. sovereign_tools_sovereignagent_kagent_sum({'a': 17, 'b': 25}) -> 42

Answer: The sum of 17 and 25 is 42.
```

## Act 2: show it in the UI, then show the trace (3 min, browser)

**This is the strongest thing on screen. Do not skip it.**

In the browser: **Agents**, open `sovereign-calc`, and prompt:

```
Add 17 and 25 using your sum tool.
```

It answers 42. Then go straight to the **Tracing** tab, open the newest trace,
and expand it.

The trace tree shows the agent turn, and inside it a span named
`execute_tool sum` with its own duration. The Execution Flow view shows
`Start → sovereign_calc (AGENT) → sum (TOOL) → End`.

Say: *that is the evidence an auditor asks for. Not "the agent answered 42",
but which tool it called, when, how long it took, and that it went through the
gateway to get there. This is the record a DORA or NIS2 obligation needs, and
none of it was instrumented by the application team. The registry stamped the
tracing endpoint in at deploy time.*

Say this too, because it turns a gap into a Google finding: *Cloud Monitoring in
this universe cannot ingest custom or OpenTelemetry metrics at all, and there is
no Cloud Trace. That is why this stack is self-hosted, in-cluster, in Germany.*

## Act 3: policy governs both agents (3 min, terminal)

```bash
kubectl -n mcp get agentgatewaypolicy mcp-tool-authz \
  -o jsonpath='{.spec.backend.mcp.authorization.policy.matchExpressions}'; echo

kubectl -n kagent get remotemcpserver everything-server \
  -o jsonpath='{.status.discoveredTools[*].name}'; echo
kubectl -n agentregistry-system get remotemcpserver \
  -o jsonpath='{.items[0].status.discoveredTools[*].name}'; echo
```

Say: *the tool server offers five tools. Both agents see two. The other three
are not blocked, they are invisible: they never appear in discovery. And note
the second one is the registry-deployed agent, so the same policy governs an
agent the platform team never touched.*

Now change it live. **This is the moment.**

```bash
kubectl -n mcp patch agentgatewaypolicy mcp-tool-authz --type=json -p '[
  {"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/1",
   "value":"mcp.tool.name == \"echo\""}]'

kubectl -n kagent delete remotemcpserver everything-server
kubectl apply -f ../../docs/demo/remotemcpserver.yaml
sleep 20
kubectl -n kagent get remotemcpserver everything-server \
  -o jsonpath='{.status.discoveredTools[*].name}'; echo
```

Now it says `echo`. Say: *one line of gateway policy. The agent's capability
changed. I did not touch the agent, the tool server, the registry, or any
application code. In a regulated environment that is the difference between
hoping an agent behaves and proving what it can do.*

**Put it back:**

```bash
kubectl -n mcp patch agentgatewaypolicy mcp-tool-authz --type=json -p '[
  {"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/1",
   "value":"mcp.tool.name in [\"sum\",\"reverse_text\"]"}]'
kubectl -n kagent delete remotemcpserver everything-server
kubectl apply -f ../../docs/demo/remotemcpserver.yaml
```

## Act 4: enforcement at protocol level (2 min, optional, technical audience)

```bash
kubectl apply -f ../../docs/demo/mcp-protocol-probe.yaml
sleep 45
kubectl -n mcp logs mcpdemo
```

`tools/list` returns only the permitted tools, `tools/call sum` succeeds, and:

```json
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Unknown tool: printenv"}}
```

Say: *`printenv` would dump the pod environment. It is filtered from discovery
and rejected on call. Defence in depth, and none of it lives in the
application.*

## Act 5: high availability (1 min, optional)

```bash
kubectl -n agentgateway-system get pdb
kubectl -n agentgateway-system get pods \
  -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o wide
```

Three data plane pods on three nodes across three zones, behind a
PodDisruptionBudget requiring two available. Because the gateway is the only
policy point in this environment, its availability is the platform's
availability.

## The closing line

*Everything you have seen runs in Germany, on hardware operated by a German
entity, with a model we host ourselves. The agent was published to a catalogue
and deployed by that catalogue. Every tool call went through one policy point
and left an audit record. In this environment, none of the alternatives you
would normally reach for exist.*

---

# WHAT NOT TO SHOW

**The `enterprise-agentgateway-waypoint` GatewayClass.** It is registered but
still fails silently: resources apply, policy reports `Accepted`, nothing is
enforced. Note this is a different thing from the Istio waypoint, which does
work: `agent-waypoint` in the `kagent` namespace uses the `istio-waypoint`
class and enforces L7 policy correctly. Mixing the two classes is what fails.

**A second `arctl build`.** The image is already built and pushed. Building live
means a multi-minute Docker push into the universe over your hotel wifi.

---

# QUESTIONS YOU WILL GET

**Is this production ready?** The architecture is. The environment is a preview
and we have open questions with Google, chiefly GPU access. The model is small
and on CPU for that reason.

**Does the agent actually call the tool?** Yes, and you can see it two ways: the
tool call is printed by `57-ar-ask.sh`, and the trace tree shows an
`execute_tool sum` span with its own duration. If someone insists a 3B model
could just add 17 and 25 itself, use the nonce proof:

```bash
NONCE=$(openssl rand -hex 10)
echo "nonce    $NONCE"
echo "expected $(python3 -c "print('$NONCE'[::-1])")"
./scripts/57-ar-ask.sh "Call the reverse_text tool with text set to $NONCE and reply with only the tool result."
```

A model this size cannot reverse a random hex string unaided, so an exact match
can only mean the tool ran.

**Who can deploy an agent?** Whoever the registry says. `arctl` authenticated as
a Keycloak user in the `admins` group; the registry maps that group to
superuser, and it is the registry's own identity that writes to the cluster, not
the user's. That indirection is the governance boundary.

**What about encryption between services?** There is mTLS, as of 2026-09-04.
Istio ambient runs here now, and every connection between enrolled workloads is
mutually authenticated on SPIFFE identity derived from the ServiceAccount. This
was our most significant finding while it was absent: GCD has no Cloud Service
Mesh and no GKE network policies, and Autopilot rejects the privileged
DaemonSets ambient needs. What changed is that GCD shipped privileged workload
allowlisting, so we could admit them. Cloud Service Mesh is still unavailable,
so be precise: this is self-managed Istio, not a managed Google service.

**Why Qwen and not Mistral or Gemma?** Practical. Gemma and Llama are gated on
Hugging Face and need an access token, and this environment has no secret
manager to hold one. Qwen is ungated and small enough for CPU. Mistral is the
European answer, Gemma matches Google's own reference designs, and either is a
values-file change once we have a GPU.

**Where does the data go?** Nowhere. Model, tools, agents, catalogue and traces
are all in this cluster in Germany. The registry's database is managed Postgres
in the same region over Private Service Connect, encrypted with our own key.

**Why do you need a port-forward and a hosts entry?** Because GCD has no public
DNS zone and no certificate service, so there is no way to publish a resolvable,
TLS-terminated name for your own console. Every software vendor with a browser
console or a CLI hits this. It is on our list for Google.

---

# RISKS, RANKED

1. **Session expiry**, roughly 45 minutes. Re-authenticate immediately before,
   and know that a `gke-gcloud-auth-plugin` error means exactly this.
2. **The port-forward dies** if the session expires. Re-source step 5.
3. **First prompt is slow** on CPU. Step 7 handles it.
4. **UI login** needs the step 1 hosts entry. Test tonight.
5. **Traces are not persisted.** ClickHouse runs without a persistent volume, so
   restarting it empties the Tracing tab. Step 7 always seeds a fresh trace.
   This is a deliberate shortcut, not a platform limit: persistent volumes work
   here, they just have a 4 GB minimum.

# FALLBACK

Acts 1, 3, 4 and 5 are entirely terminal. No browser login and no UI. Act 1
does not need the model to answer at all up to the point of the `ask`, and the
policy flip in Act 3 is the strongest thing in the demo while depending on
nothing fragile. If the UI or the model misbehaves, run those and you still have
the whole argument.

# RESET BLOCK

If anything is left in a strange state:

```bash
cd ~/code/google-sov

# gateway policy back to two tools
kubectl -n mcp patch agentgatewaypolicy mcp-tool-authz --type=json -p '[
  {"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/1",
   "value":"mcp.tool.name in [\"sum\",\"reverse_text\"]"}]'

# hand-written agent's tool binding
kubectl -n kagent delete remotemcpserver everything-server --ignore-not-found
kubectl apply -f docs/demo/remotemcpserver.yaml
kubectl -n kagent rollout restart deploy/sovereign-calc
kubectl -n kagent rollout status deploy/sovereign-calc --timeout=180s

# registry-deployed agent, rebuilt from the catalogue (skips the image build)
cd poc/2026-09-agentic-platform
SKIP_BUILD=1 ./scripts/56-ar-push-agent.sh

sleep 20
kubectl -n kagent get remotemcpserver everything-server \
  -o jsonpath='{.status.discoveredTools[*].name}'; echo
```
