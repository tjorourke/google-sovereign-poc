# Sizing pods on GKE Autopilot in GCD

**Short version:** every container you deploy must set `resources.requests`. Not
for performance. For capacity. A container that does not is DEFAULTED by
Autopilot to **500m CPU and 2Gi memory**, that default is a real reservation,
and GKE on GCD is C3-only with **24 vCPU** in this project.

## The mechanism

On GKE Standard, a container with no `resources` block reserves nothing: it is
best-effort and packs onto a node you are already paying for. Autopilot has no
nodes you manage — you pay for what pods *request*, and the scheduler provisions
nodes to fit them. So Autopilot cannot run a container with no request. It
injects one, and tells you:

```
Warning: autopilot-default-resources-mutator: Autopilot updated Deployment
cert-manager/cert-manager: defaulted unspecified 'cpu' resource for
containers [cert-manager-controller]
```

That is not advisory. It is the cluster writing `cpu: 500m, memory: 2Gi` into
your pod spec, per container, and reserving it.

`requests` is what matters here, not `limits`. A request is a reservation the
scheduler must satisfy, and satisfying it provisions nodes, and nodes consume
vCPU quota — whether the container ever uses the CPU or not.

## What it actually costs

Measured on this stack, 2026-09-05. cert-manager's real usage against what
Autopilot had reserved for it:

| | requested (defaulted) | actually used |
|---|---|---|
| cert-manager | 500m / 2Gi | **1m / 19Mi** |
| cert-manager-cainjector | 500m / 2Gi | **1m / 53Mi** |
| cert-manager-webhook | 500m / 2Gi | **1m / 9Mi** |

Twelve such containers held **6000m — a quarter of the entire 24-vCPU quota** —
for controllers that together use about 15m.

The failure this produces arrives much later and blames the wrong thing:

```
Warning FailedScaleUp: Node scale up in zones u-germany-northeast1-c
associated with this pod failed: GCE quota exceeded.
```

That names whichever pod happened to be scheduled last. Nothing points back at
the twelve oversized reservations that consumed the budget. On this stack it
stranded the AccessPolicy waypoint pods at phase 67, six phases after the cause.

## Where to set it, per component

Most charts take a helm value. Two things do NOT, and that is the part people
get wrong.

| Component | How | Value |
|---|---|---|
| cert-manager | helm | `resources`, `webhook.resources`, `cainjector.resources` |
| External Secrets | helm | `resources`, `webhook.resources`, `certController.resources` |
| kube-prometheus-stack | helm | `prometheus.prometheusSpec.resources`, `prometheusOperator.resources`, `kube-state-metrics.resources`, `grafana.resources`, `grafana.sidecar.resources` |
| Keycloak | our own manifest | `spec.containers[].resources` |
| Transient probe pods | `kubectl run --overrides` | a `curl` defaulted to 500m is 2% of the cluster |
| **agentgateway data plane** | **`AgentgatewayParameters` CRD** | the chart's `resources` reaches the CONTROLLER only |
| **Istio waypoints** | **controller-generated** | same shape of problem |

The last two are the trap. The proxy pods are created by a controller from
Gateway resources, so no helm value reaches them. Attach an
`AgentgatewayParameters` and reference it from the Gateway:

```yaml
spec:
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: right-sized
```

Measured effect: 500m/2Gi -> 100m/256Mi per proxy pod.

## Do NOT right-size istio-cni or ztunnel

Ambient is the exception, and getting this wrong is expensive.

Both charts already ship explicit requests, so Autopilot never defaulted them,
and they are modest against real usage:

| | requested | actually used |
|---|---|---|
| istio-cni (install-cni) | 100m / 103Mi | **1m / ~25Mi** |
| ztunnel (istio-proxy) | 200m / 512Mi | **1-4m / ~9Mi** |

None of the wasted capacity on this stack was Istio's.

More importantly: a `WorkloadAllowlist` pins the container spec, and the spec
includes `resources`. Change a CPU request on either DaemonSet and the rendered
pod stops matching the allowlist GKE generated for it. Warden then rejects the
DaemonSet citing **capabilities and hostPath** and says nothing about resources,
which sends you looking in entirely the wrong place.

If you do need to change them, it is not a one-line edit. Regenerate the
allowlist, re-upload it, and re-authorise the paths on the org policy and the
cluster -- a ~20 minute cluster update. Treat ambient's resources as part of the
admission contract, not as a tuning knob.

## What NOT to shrink

Not every 500m is Autopilot's doing. Solo's istiod chart sets `500m / 2048Mi`
deliberately, and says so: *"Resources for a small pilot install"*. That is a
considered value for a control plane that does real work. Check whether a chart
chose the number before assuming a mutator did — the fastest way is to read the
chart's own values:

```bash
helm show values <chart> --version <v> | grep -A4 'resources:'
```

## Rule of thumb for this stack

Controllers and webhooks idle near zero. 50m/128Mi is generous for them.
Data planes and anything that stores or queries data want more:

| Class | requests |
|---|---|
| Controllers, webhooks, sidecars | 50m / 128Mi |
| Gateways and proxies | 100m / 256Mi |
| Keycloak, UI backends | 100m / 512Mi |
| Prometheus | 200m / 512Mi |
| ClickHouse, model servers | size deliberately; these genuinely need it |

Set them explicitly even where they match the chart default. An explicit value
survives a chart upgrade changing its mind; an omission is an invitation for
Autopilot to pick 500m again.
