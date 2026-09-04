# What we tested through agentgateway on Google Cloud Dedicated (Berlin)

**Project:** `eu0:soloio-eval` · **Region:** `u-germany-northeast1` · **Date:** 2026-09-03
**Cluster:** GKE Autopilot `agentic`, `v1.35.6-gke.1049000`, private nodes
**Companion document:** `gcd-berlin-deployment.md` (the infrastructure this runs on)

This is the functional record: the agentic path we exercised, the self-hosted model and its
configuration, the kagent agent and MCP wiring, and where AgentRegistry sits. Every manifest below
is the one actually applied.

The point of the exercise, as originally framed: GCD had **no service mesh by any route**, so
agentgateway was not the best way to govern agent traffic but the only way. That framing held for
most of this evaluation and it is why the test below uses no mesh at all.

**Superseded on 2026-09-04.** Istio ambient now runs here, admitted through customer-owned
`WorkloadAllowlist` objects, with workload mTLS and L4 and L7 authorization all verified enforcing.
See `istio-ambient-on-gcd-autopilot.md`. Everything below still stands on its own terms: it is the
record of what agentgateway does at the agent and tool layer, which is a different job from what a
mesh does at the workload layer, and the two now compose. The honest statement to a customer is that
agentgateway governs which tools an agent may call, and ambient governs which workloads may talk to
each other at all.

---

## The path under test

```
kagent Agent (sovereign-calc)
      │
      ├── model traffic ──► agentgateway ──► llama.cpp / Qwen2.5-0.5B-Instruct
      │                     (LLM policy)     self-hosted on C3 CPU, in-universe
      │
      └── tool traffic  ──► agentgateway ──► everything-server (MCP, 5 tools)
                            (MCP tool authz, filters 5 tools to 1)
```

Both legs go through the gateway deliberately. Pointing kagent at `llm.model.svc` or
`everything-server.mcp.svc` directly would work and would bypass every control, which is exactly
the failure mode a customer needs to be prevented from choosing.

---

## 1. The model: self-hosted, in-universe, no GPU

GCD has no `aiplatform`, so there is no managed model endpoint of any kind. Google's own GCD
reference architectures answer this by self-hosting open-weight Gemma on A3/H100 — but **there is
no `NVIDIA_H100_80GB_GPUS` quota metric in this project at all**, even though `nvidia-h100-80gb` is
offered in two zones. So GPU inference was not available to us, and we fell back to CPU, which is
what Google's own Compute Engine differences page suggests when A3 is too large.

We used **llama.cpp** rather than vLLM: it is CPU-native and serves an OpenAI-compatible `/v1`
surface, which is what both kagent and agentgateway expect. The model is
**Qwen2.5-0.5B-Instruct (Q4_K_M GGUF)**, chosen because it is **not gated on Hugging Face** — which
matters in a universe with no Secret Manager to hold an access token.

It downloads its weights at start-up over Cloud NAT, which is itself a useful proof that egress
works from a private node.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: model
  labels: { app: llm }
spec:
  replicas: 1
  selector: { matchLabels: { app: llm } }
  template:
    metadata: { labels: { app: llm } }
    spec:
      containers:
        - name: server
          image: ghcr.io/ggml-org/llama.cpp:server
          args:
            - -hf
            - Qwen/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M
            - --host
            - 0.0.0.0
            - --port
            - "8080"
            - -c
            - "4096"
            - --jinja
          ports: [{ containerPort: 8080, name: http }]
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 60
          resources:
            requests: { cpu: "2", memory: 4Gi }
            limits: { cpu: "3", memory: 6Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: llm
  namespace: model
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
```

Ready in under two minutes including the weight download.

### Fronting the model with agentgateway

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: llm
  namespace: model
spec:
  ai:
    provider:
      # `openai` names the wire FORMAT here, not the vendor. llama.cpp serves an
      # OpenAI-compatible surface, so a self-hosted model gets the same LLM
      # policy, budget and audit treatment as a SaaS provider would.
      openai:
        model: Qwen2.5-0.5B-Instruct
      host: llm.model.svc.cluster.local
      port: 8080
      pathPrefix: /v1
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm
  namespace: model
spec:
  parentRefs: [{ name: agentgateway-proxy, namespace: agentgateway-system }]
  hostnames: ["llm.agentic.eu0.internal"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: llm
```

The backend reported `Accepted=True`. The hostname resolves through the Cloud DNS **private** zone
we provisioned, pointed at the gateway's internal load balancer.

**A field shape worth recording**, because we got it wrong first: the `ai` block is
`spec.ai.provider.{openai,anthropic,gemini,bedrock,vertexai,azure,custom}` plus sibling `host`,
`port`, `path`/`pathPrefix`. It is **not** `spec.ai.llm` / `spec.ai.host`, which the API rejects
with `strict decoding error: unknown field "spec.ai.host"`.

---

## 2. The MCP server and tool-level authorization

`everything-server` is a FastMCP Python server exposing five tools: `sum`, `echo`, `to_uppercase`,
`reverse_text` and **`printenv`** — the last being the one that leaks the pod environment and should
never be reachable.

Built `--platform linux/amd64` (GCD has C3/M3/A3 only, no Arm machine types whatsoever) and pushed
to the in-universe Artifact Registry at
`docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/everything-server:latest`.

### The backend and the policy

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
          port: 3000
          path: /mcp
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: everything-server-mcp
  namespace: mcp
spec:
  parentRefs: [{ name: agentgateway-proxy, namespace: agentgateway-system }]
  hostnames: ["mcp.agentic.eu0.internal"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /mcp } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: everything-server-mcp
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-tool-authz
  namespace: mcp
spec:
  # Attached to the BACKEND, not the Gateway or the HTTPRoute. That is what gives
  # the gateway MCP context — including the tool name — when it evaluates a rule.
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: everything-server-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          # matchExpressions are OR-ed. A tool is visible to a caller only if at
          # least one expression is true; anything unmatched is filtered from
          # tools/list and short-circuited on tools/call.
          matchExpressions:
            - 'jwt.Groups.exists(g, g == "admins")'
            - 'mcp.tool.name == "sum"'
```

### What the gateway actually did

A full MCP handshake through the gateway — `initialize`, then `tools/list` and `tools/call` with the
returned `Mcp-Session-Id`:

```
=== 1. initialize
session: <redacted MCP session id>...

=== 2. tools/list
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"sum","description":"Add two numbers
together...","inputSchema":{...}}]}}
        ^ only ONE tool returned. The other four are filtered out entirely.

=== 3. tools/call sum
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"5"}],
 "structuredContent":{"result":5},"isError":false}}

=== 4. tools/call printenv
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Unknown tool: printenv"}}
```

The denied tool is not merely refused, it is **invisible** — filtered from discovery, so a model
never learns it exists, and then rejected at call time as a defence in depth.

Cluster state at the time, for the avoidance of doubt:

```
istio namespaces: 0
ztunnel pods:     0
GatewayClasses:   enterprise-agentgateway, enterprise-agentgateway-waypoint (registered, unused)
proxy replicas:   3
```

Verbatim transcript: `feedback/google/evidence/berlin-mcp-tool-authz-2026-09-03.txt`.

---

## 3. The kagent agent

### Model configuration

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: selfhosted
  namespace: kagent
spec:
  provider: OpenAI
  model: Qwen2.5-0.5B-Instruct
  apiKeySecret: llm-key          # a dummy value; the local model is keyless
  apiKeySecretKey: OPENAI_API_KEY
  openAI:
    # Through the GATEWAY, by hostname. Using the Service DNS name would skip
    # the hostname-matched HTTPRoute and the gateway answers "route not found".
    baseUrl: http://llm.agentic.eu0.internal/v1
    maxTokens: 512
    temperature: "0.2"
```

Reported `Accepted=True — Model configuration accepted`.

### MCP server registration

```yaml
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: everything-server
  namespace: kagent
spec:
  description: Approved org tool server, reached through agentgateway
  # Also by hostname, and also through the gateway. Pointing this at
  # everything-server.mcp.svc.cluster.local directly would bypass the policy.
  url: http://mcp.agentic.eu0.internal/mcp
  protocol: STREAMABLE_HTTP
  timeout: 30s
  terminateOnClose: true
```

### The agent

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: sovereign-calc
  namespace: kagent
spec:
  type: Declarative
  description: >-
    Demonstrates a sovereign agentic path on Google Cloud Dedicated: the model is
    self-hosted in-universe, and both the model and the tools are reached through
    agentgateway, which is the only policy and audit point available here.
  declarative:
    modelConfig: selfhosted
    systemMessage: |
      You are a careful arithmetic assistant running inside a sovereign cloud.
      When asked to add numbers, you MUST use the `sum` tool rather than
      calculating yourself. If a tool you need is not available to you, say so
      plainly and name the tool. Never guess.
    tools:
      - type: McpServer
        mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: everything-server
          namespace: kagent
          toolNames:
            - sum
```

`Accepted=True`, deployment `1/1`, serving its A2A agent card at
`/.well-known/agent-card.json` as `sovereign_calc`.

### What the agent returned

```
POST /  message/send  "Use your sum tool to add 17 and 25. Reply with just the number."

"state":"completed"
"text":"17 + 25 = 42"
```

---

## 4. The result that actually proves the control

The `42` answer on its own proves the agent works end to end, but **not** that the tool was invoked
— a model can add two small numbers unaided, and Qwen2.5-0.5B is small enough that its tool-calling
is unreliable. We are not going to claim more than we measured.

The decisive test is the control plane, not the completion. We changed one line of the gateway
policy from `mcp.tool.name == "sum"` to `mcp.tool.name == "echo"` and re-registered the MCP server:

| Gateway policy allows | kagent's discovered tools |
|---|---|
| `sum` | `['sum']` |
| `echo` | `['echo']` |

**The agent's entire capability surface is determined by gateway policy, not by what the MCP server
exposes.** `everything-server` never changed; it always advertised five tools. kagent only ever saw
the one the gateway permitted, and the change propagated without touching the agent, the MCP server,
or any application code.

That is the property a regulated customer is buying, and it held with no mesh in the cluster.

**What we did not prove**, stated plainly: that this particular 0.5B model reliably chooses to call
the tool. That is a model-capability question, not a platform one, and it would be answered by
running the same wiring against Gemma 3 27B on A3/H100 once GPU quota exists.

---

## 5. AgentRegistry as the deployer, not just the catalogue

AgentRegistry Enterprise 2026.6.1 runs against a dedicated Cloud SQL database over Private Service
Connect, with OIDC wired to the same Keycloak realm as kagent and the split audience mappers the
platform needs (`ar-*` -> `aud: ar-backend`, `kagent-*` -> `aud: kagent-backend`).

We then closed the loop that matters commercially: **an agent published to the catalogue and
deployed into the cluster by the catalogue**, with no `kubectl` at any point. This is the governance
property a regulated buyer asks about, because it puts a reviewable inventory between a developer
and a running workload.

### Reaching the registry from a CLI, which GCD makes awkward

`arctl` is a laptop CLI and the registry has no public address. Two GCD properties get in the way,
and both are worth stating to Google because they generalise to any ISV with a CLI:

1. **No public DNS zone.** The registry and the OIDC issuer both live behind a Cloud DNS private
   zone and an internal load balancer, so a laptop cannot resolve or route to either. Earlier in
   this evaluation that read as a hard blocker. It is not: a `kubectl port-forward` reaches the
   registry with no DNS at all, and we also added a second, external `Service` in front of the
   existing gateway pods so the same host-based HTTPRoutes are reachable from outside the VPC. The
   gateway's own internal address is left untouched.

2. **No TLS, and therefore no laptop token minting.** The registry validates the issuer as
   `http://keycloak.agentic.eu0.internal/realms/agentregistry`. GCD has neither
   `certificatemanager` nor `privateca`, so that endpoint is plaintext HTTP, and minting a token
   from a laptop means POSTing a username and password over cleartext. Endpoint protection on a
   corporate laptop classifies that as credential phishing and returns a block page instead of a
   token. We mint inside the cluster instead, which both sidesteps the interception and produces a
   token carrying exactly the issuer the registry expects.

`poc/2026-09-agentic-platform/scripts/55-arctl-connect.sh` does both and is sourced, not run.

### The catalogue records

Two records, applied with `arctl`. Neither is a Kubernetes object: AgentRegistry ships no CRDs and
stores these in Postgres.

The tool server is catalogued as a **remote** MCP server whose URL is agentgateway's MCP listener,
never the tool server's own Service. That single choice is what makes the catalogue govern by
construction: anything the catalogue hands out is reached through the only policy point available in
this universe.

```yaml
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: sovereign-tools
spec:
  title: Governed tool server
  description: >-
    Approved arithmetic and text tools, reached only through agentgateway so
    that per-tool authorization and audit apply. The backing server offers five
    tools; gateway policy decides which of them an agent can discover.
  remote:
    type: http
    url: http://mcp.agentic.eu0.internal/mcp
```

The agent record points at an image in the in-universe Artifact Registry and references the
catalogued tool server by name. It carries no endpoint and no credential:

```yaml
apiVersion: ar.dev/v1alpha1
kind: Agent
metadata:
  name: sovereignagent
spec:
  description: 'Sovereign demo agent: pushed to kagent from AgentRegistry, reaches
    its model and tools only through agentgateway.'
  modelName: Qwen2.5-3B-Instruct
  modelProvider: openai
  source:
    image: docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/sovereignagent:0.1.0
  mcpServers:
    - kind: MCPServer
      name: sovereign-tools
```

The image was scaffolded and built with `arctl` and pushed into the universe. Two Berlin specifics
apply: `--platform linux/amd64`, because GCD has no Arm compute, and a token-based `docker login`
rather than the gcloud credential helper, which rejects this registry host (finding 05).

```bash
arctl build sovereignagent --push --platform linux/amd64   --image docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/sovereignagent:0.1.0
```

### The push

This is the object that moves the agent from catalogue to cluster. `targetRef` resolves to the
catalogued agent, `runtimeRef` to a registered runtime:

```yaml
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: sovereignagent-kagent
spec:
  targetRef:  { kind: Agent,   name: sovereignagent }
  runtimeRef: { kind: Runtime, name: kubernetes-default }
  env:
    OPENAI_BASE_URL: http://llm.agentic.eu0.internal/v1
    OPENAI_API_KEY: sovereign-local-noauth
    MCP_SERVERS_CONFIG: '[{"name":"sovereign-tools","type":"remote","url":"http://mcp.agentic.eu0.internal/mcp"}]'
```

`kubernetes-default` is a runtime the registry seeds itself, with no kubeconfig in its spec, so it
acts through the registry's own in-cluster ServiceAccount. On GCD that is the right shape: the kind
labs put a kubeconfig in `spec.config.kubeconfig` because the registry had to reach a cluster across
a Docker network, and none of that applies here. The ServiceAccount's authority is narrow and
checkable:

```
$ kubectl auth can-i create agents.kagent.dev -n kagent     --as=system:serviceaccount:agentregistry-system:agentregistry-enterprise
yes
$ kubectl auth can-i create deployments.apps -n kagent --as=...
no
```

It can create kagent resources and cannot create raw workloads. kagent's controller does that part.

### What the registry created

```
$ kubectl get agents.kagent.dev -A
NAMESPACE              NAME                                     TYPE          READY   ACCEPTED
agentregistry-system   sovereignagent-latest-sovereignagent-k   BYO           True    True
kagent                 sovereign-calc                           Declarative   True    True

$ kubectl get remotemcpservers.kagent.dev -A
NAMESPACE              NAME                               PROTOCOL          URL                                   ACCEPTED
agentregistry-system   sovereign-tools-sovereignagent-k   STREAMABLE_HTTP   http://mcp.agentic.eu0.internal/mcp   True
kagent                 everything-server                  STREAMABLE_HTTP   http://mcp.agentic.eu0.internal/mcp   True
```

Two agents now exist by two different routes. `sovereign-calc` was written by hand with `kubectl`.
`sovereignagent` was catalogued and then deployed by the registry, which also created its tool
binding and its workload.

The registry injects the deploy-time configuration, which is why the image is portable:

```
image:                  docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/sovereignagent:0.1.0
OPENAI_BASE_URL         http://llm.agentic.eu0.internal/v1
MODEL_NAME              Qwen2.5-3B-Instruct
MCP_SERVERS_CONFIG      [{"name":"sovereign-tools-sovereignagent-kagent","type":"remote","url":"http://mcp...
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  http://solo-enterprise-telemetry-collector.solo-enterprise:4317
OTEL_TRACING_ENABLED    true
```

Note the last two. The registry stamps the tracing endpoint into every agent it deploys, so the
audit trail is a property of the platform rather than something an application team remembered to
add. Confirmed landing in ClickHouse:

```
$ clickhouse-client -q "SELECT ServiceName, count() FROM platformdb.otel_traces_json GROUP BY ServiceName"
sovereignagent   18
```

### The governed call

```
$ ./scripts/57-ar-ask.sh "Add 17 and 25 using your sum tool."

Tools the agent called:
  1. sovereign_tools_sovereignagent_kagent_sum({'a': 17, 'b': 25}) -> 42

Answer: The sum of 17 and 25 is 42.
```

And the same gateway policy governs it. The registry-deployed agent discovers two tools out of the
five the server offers, exactly as the hand-written one does:

```
$ kubectl -n agentregistry-system get remotemcpserver sovereign-tools-sovereignagent-k \
    -o jsonpath='{.status.discoveredTools[*].name}'
reverse_text sum
```

That is the point worth making to a customer. Policy attaches to the tool server at the gateway, so
it governs every agent that reaches it, including one the platform team never touched and did not
write.

---

## 6. Availability posture of the gateway

Because the gateway is the only policy point, its availability is the platform's availability.

| Tier | Replicas | Protection |
|---|---|---|
| `agentgateway-proxy` (data plane) | 3 | PDB `minAvailable: 2`; spread by **zone and hostname** |
| `enterprise-agentgateway` (control plane) | 2 | PDB `minAvailable: 1` |

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: proxy-ha
  namespace: agentgateway-system
spec:
  deployment:
    spec:
      replicas: 3
      template:
        spec:
          topologySpreadConstraints:
            # Zone spread alone is NOT enough. With maxSkew 1 over three zones the
            # scheduler was satisfied by three pods on ONE node — nominally spread,
            # actually zero resilience. The hostname constraint is what fixes it.
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: DoNotSchedule
              labelSelector:
                matchLabels:
                  gateway.networking.k8s.io/gateway-name: agentgateway-proxy
            - maxSkew: 1
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: DoNotSchedule
              labelSelector:
                matchLabels:
                  gateway.networking.k8s.io/gateway-name: agentgateway-proxy
  podDisruptionBudget:
    spec:
      minAvailable: 2
```

Resulting placement — 3 pods, 3 distinct nodes, 3 distinct zones:

```
agentgateway-proxy-5c8855f9c7-dhvzq   node=bc34332-fr4r   zone=u-germany-northeast1-b
agentgateway-proxy-5c8855f9c7-nt646   node=dc56d26-lck6   zone=u-germany-northeast1-c
agentgateway-proxy-5c8855f9c7-qtnph   node=9804948-scqt   zone=u-germany-northeast1-a
```

`whenUnsatisfiable: DoNotSchedule` rather than `ScheduleAnyway` is the part that matters — it forces
Autopilot to provision nodes in the other zones instead of packing.

We also set `sessionAffinity: ClientIP` on the gateway Service. MCP is session-based: `initialize`
returns an `Mcp-Session-Id` that later calls must present, and that session lives in the proxy
replica that handled it. Three replicas without affinity is a latent failure for any MCP client that
does not reuse its connection.

**Still single-replica and on the request path**, so worth scaling before anyone calls this
production: `ext-auth-service`, `ext-cache`, `rate-limiter` and `waf-server`.

---

## 7. Honest limitations of this test

- **No workload mTLS.** There is no mesh, so traffic between the agent, the gateway, the model and
  the MCP server is plain HTTP inside the cluster. Tool authorization and audit survive; identity-
  based encryption between workloads does not.
- **No transparent interception.** The agent must be *pointed at* the gateway. On a mesh-capable
  cluster a waypoint would intercept whatever the agent dialled. Here, a manifest that points
  directly at `everything-server.mcp.svc` bypasses every control — so this has to be enforced by
  review or admission policy (Kyverno would be the natural addition) rather than by the network.
- **The waypoint GatewayClass is a trap.** `enterprise-agentgateway-waypoint` is registered and a
  waypoint Deployment *will* schedule, and the policy *will* report `Accepted` — but nothing
  redirects traffic to it without ztunnel, so nothing is enforced. Silent failure of a security
  control. Use the standalone path, as we did.
- **The model is a 0.5B toy.** Adequate to prove the wiring, inadequate to demonstrate agent
  quality. The blocker is GPU quota, not architecture.
- **HTTP only.** No Certificate Manager, no Private CA, no public DNS zone, so no ACME by either
  challenge type. TLS on the edge is BYO and hand-rotated.

---

## What we would do next

1. Scale the four single-replica request-path services and add PodDisruptionBudgets to Keycloak,
   kagent and AgentRegistry.
2. Move Keycloak to production mode on Cloud SQL — it is the last component on a development
   posture.
3. Stand up the Tier 1 regional external ALB with Cloud Armor and a BYO certificate, which also
   unblocks `arctl` and the AgentRegistry catalogue flow.
4. Add Kyverno to enforce "agents may only reference gateway-fronted backends", replacing the
   NetworkPolicy that GCD does not have.
5. Swap in Gemma 3 27B on A3/H100 once GPU quota exists, and re-run this test to measure agent
   quality rather than just wiring.
