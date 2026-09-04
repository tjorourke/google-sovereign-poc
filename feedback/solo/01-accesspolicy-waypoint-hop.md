# 01 — AccessPolicy's generated Istio policy omits the waypoint's own identity

**Product:** Solo Enterprise for kagent 0.4.3 (`policy.kagent-enterprise.solo.io/v1alpha1`)
**Severity:** major — silent failure, and the error message points at the wrong component
**Date raised:** 2026-09-04
**Environment:** GKE Autopilot 1.35.6, Istio 1.30.4 ambient, `controller.istioAuthzTranslation.enabled=true`

## What we did

Authored the documented tool-scoping policy against a waypoint-fronted MCPServer:

```yaml
apiVersion: policy.kagent-enterprise.solo.io/v1alpha1
kind: AccessPolicy
metadata: { name: allow-sum-only, namespace: agents }
spec:
  action: ALLOW
  from:
    subjects: [{ kind: Agent, name: waypoint-calc, namespace: agents }]
  targetRef:
    kind: MCPServer
    name: everything-server      # labelled kagent.solo.io/waypoint: "true"
    tools: [sum]
```

`status.state` becomes `Applied` and both halves are generated, as documented.

## What happened

The L7 half is correct:

```yaml
# EnterpriseAgentgatewayPolicy/accesspolicy-allow-sum-only-waypoint
matchExpressions:
  - (source.identity.namespace == "agents" &&
     source.identity.serviceAccount == "waypoint-calc") && (mcp.tool.name == "sum")
```

The L4 half names only the subject:

```yaml
# AuthorizationPolicy/accesspolicy-allow-sum-only-waypoint
selector: { matchLabels: { app.kubernetes.io/name: everything-server } }
rules:
  - from: [{ source: { principals: ["cluster.local/ns/agents/sa/waypoint-calc"] } }]
```

But with a waypoint in front of the MCPServer, the agent never connects to the
tool server. The waypoint does. The identity arriving at the server is
`cluster.local/ns/agents/sa/mcpserver-everything-server-waypoint`, which that
ALLOW policy does not name, so the hop is refused.

kagent's controller is affected too: it performs tool discovery itself, as
`cluster.local/ns/kagent/sa/kagent-controller`, and is equally denied.

## Why it is hard to diagnose

The reported error blames the tool server for an auth failure:

```
error="mcp: failed to send message: http upstream error: http request failed:
       upstream call failed: Connect: unexpected status: 401 Unauthorized"
```

The tool server did not return 401. It logs **no request at all**, because the
connection never reached it. Meanwhile:

- `MCPServer.status.discoveredTools` is empty, with no condition explaining why.
  All other conditions report success: `Accepted=True`, `ResolvedRefs=True`,
  `Programmed=True`.
- The Agent reconciles to `Ready=True` with no tools.
- At runtime the agent silently has no tools and improvises. Ours fell back to
  `ask_user` and `adk_request_confirmation`, asking the human to do the
  arithmetic, six times.

So a correct-looking AccessPolicy produces an agent that reports
`Ready`, has no tools, and blames the user. Removing the AccessPolicy makes
`tools/list` return 200 immediately, which is what isolated it.

## Workaround

An additive ALLOW for the waypoint's own identity and the controller:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: allow-waypoint-to-toolserver, namespace: agents }
spec:
  selector: { matchLabels: { app.kubernetes.io/name: everything-server } }
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/agents/sa/mcpserver-everything-server-waypoint
              - cluster.local/ns/kagent/sa/kagent-controller
```

This does not weaken tool authorization: the per-tool decision is still made at
the waypoint by the generated `EnterpriseAgentgatewayPolicy`, on the agent's
proven identity. With it in place, enforcement is exactly as intended — the
agent calls `sum` and cannot see `echo`, which it also requested.

## Suggested fix

When `targetRef` resolves to an MCPServer carrying
`kagent.solo.io/waypoint: "true"`, the translator should include the waypoint's
ServiceAccount, and kagent's controller identity, in the generated
`AuthorizationPolicy`. It provisioned that waypoint, so it knows the name.

Failing that, two cheaper improvements would each have saved us the
investigation:

1. Surface a condition on `MCPServer` when tool discovery fails, rather than
   leaving `discoveredTools` empty with everything reporting success.
2. Do not report an upstream connection failure as `401 Unauthorized`. It sent
   us looking for an authentication problem at the tool server.

## Also worth documenting

`AccessPolicy` is refused in the `kagent` namespace:

```
policies cannot be applied to namespace kagent because it is a reserved namespace
```

That is reasonable, and it is not stated in the CRD description or the field
docs. Agents and tool servers intended to be governed must live in their own
namespace. Every Solo lab does this; none says why.
