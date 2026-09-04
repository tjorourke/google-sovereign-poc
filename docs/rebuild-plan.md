# Rebuild plan: tear down and stand up from scratch

Written 2026-09-04. Plan only, nothing executed.

Goal: destroy the current environment and recreate it on a new Autopilot cluster,
with Istio ambient and the Solo agentic stack, driven by scripts rather than by
hand.

## Read this first: the honest state of the scripts

The chain in `poc/2026-09-agentic-platform/README.md` was built incrementally
while we were discovering the environment, and **has never been run end to end
from an empty project.** Several things done in the last two days were done by
hand at a terminal and are not in any script. A rebuild attempted today would
stall at each of those points.

So the plan has three parts, and the middle one is the real work:

1. Tear down (about 40 minutes, mostly waiting)
2. **Close the scripting gaps** (about half a day)
3. Stand up (about 2 hours of wall-clock, mostly waiting)

Doing 3 before 2 will not work. Listing the gaps is the most useful part of this
document.

---

## Part 1: what is missing from the scripts

### Not scripted at all

| Thing | Done by hand as | Where it should live |
|---|---|---|
| Allowlist upload to GCS | `gcloud storage cp` | new `63-allowlist-install.sh` |
| Managed org policy for allowlist paths | `gcloud org-policies set-policy` | new `63-allowlist-install.sh` |
| Cluster `--autopilot-privileged-admission` | `gcloud container clusters update` | new `63-allowlist-install.sh` |
| `AllowlistSynchronizer` apply | `kubectl apply` | new `63-allowlist-install.sh` |
| `agents` namespace, enrolment, secret and ModelConfig copies | four `kubectl` commands | new `67-accesspolicy-setup.sh` |
| Waypoint `MCPServer`, `Agent`, `AccessPolicy`, companion policy | `kubectl apply` of four manifests | new `67-accesspolicy-setup.sh` |
| `keycloak-external` LoadBalancer | `kubectl expose` by hand | `30-keycloak.sh`, behind a flag |
| `agentgateway-proxy-external` LoadBalancer | manifest applied by hand | `80-ingress.sh`, behind a flag |
| ClickHouse `ephemeral-storage` fix | `helm upgrade --set` | `45-telemetry.sh` |

### Scripted but wrong or incomplete

| Script | Problem |
|---|---|
| `40-kagent.sh` | Does not set `controller.istioAuthzTranslation.enabled=true`. Without it `AccessPolicy` never compiles, and the waypoint label is never stamped on Agents. |
| `99-teardown.sh` | Namespace list omits `agents` and `istio-system`. Does not remove the `AllowlistSynchronizer`, the org policy, or the cluster's allowlist paths. |
| `64-istio-ambient.sh` | Correctly *asserts* the allowlists are installed but cannot install them. That is `63`'s job and `63` does not exist. |
| `60-model.sh` | Still targets Gemma via vLLM. What actually runs is Qwen2.5-3B-Instruct on llama.cpp, because vLLM's standard image is CUDA-only and Gemma is gated on Hugging Face. The script does not reflect the deployed reality. |
| `68-agent-mesh-policies.sh` | Written but never run. It closes the bypass gap on the standalone gateway path. Should be exercised during the rebuild, since a fresh environment is the safe place to find out. |

### Ordering change worth making

In the current environment, Istio was installed **after** the platform, so
namespaces were enrolled retroactively. That works — istio-cni captures running
pods in place — but it is not the order to rebuild in.

Install ambient **before** the platform, so every workload is born into the mesh
and the waypoint is available from the start. That also removes the need to
restart anything to pick up capture.

One hard constraint on that: allowlist generation needs a live cluster, because
it works by server-side dry-run against Warden. So the cluster must exist before
`62`, and `62`/`63`/`64` sit between the cluster and the platform.

---

## Part 2: teardown

### What is safe to destroy, and what will refuse

`99-teardown.sh` is deliberately not a single flag, and that is correct. Two
things will not simply destroy:

- **KMS keys carry `prevent_destroy`.** `tofu destroy` will refuse rather than
  orphan encrypted data. Either keep the key ring and reuse it, or knowingly
  remove the lifecycle block first. **Recommendation: keep it.** The keys are
  reusable, rotation is already configured, and re-creating them buys nothing.
- **Load balancers must go before the network.** Deleting namespaces first lets
  the LBs and NEGs clean up. A failed LB delete leaves orphans that then block
  the VPC destroy.

### Order

```
1. Kubernetes workloads          ./scripts/99-teardown.sh workloads
                                 add agents and istio-system to its list first
2. Allowlist plumbing            not scripted yet. By hand:
                                   kubectl delete allowlistsynchronizer istio-ambient
                                   gcloud container clusters update … \
                                     --autopilot-privileged-admission='gke://*'
3. Cloud infrastructure          ./scripts/99-teardown.sh infra
                                 tofu destroy, prompts for the project id
4. Orphan sweep                  forwarding rules, target pools, NEGs, addresses
                                 the teardown script lists what to check
```

Leave alone deliberately:

- **The KMS key ring.** As above.
- **The managed org policy.** `container.managed.autopilotPrivilegedAdmission`
  is organisation-scoped, so it survives cluster teardown and a new cluster in
  the same org inherits it. If the allowlist paths change, the policy needs
  updating; if they are the same, nothing to do. A directory prefix would be
  nicer but is **not honoured** — the synchroniser compares paths exactly, so
  every object must be named. Tested; see the evidence file.
- **The allowlist bucket** if the paths are unchanged, since it is cheap and
  re-uploading is trivial. It is a tofu-managed resource, so a full destroy will
  take it; recreating is one apply.

Roughly 40 minutes, most of it waiting on Cloud SQL and the cluster.

---

## Part 3: standup

Assumes the gaps in Part 1 are closed first.

### Phase 0: prerequisites

```
./scripts/gcd-auth.sh              # from the repo root, two browser flows
./scripts/05-validate.py           # offline manifest parse
./scripts/08-enable-apis.sh        # a fresh GCD project has only 9 services on
./scripts/00-preflight.sh          # 17 read-only probes, writes evidence
```

### Phase 1: infrastructure

```
./scripts/10-tofu.sh plan
./scripts/10-tofu.sh apply         # foundation → service agents → platform
./scripts/20-cluster-probes.sh
./scripts/15-mirror-images.sh      # 29 images into the in-universe registry
./scripts/25-cluster-baseline.sh   # cert-manager, External Secrets, Prom+Grafana
```

Two traps already handled in the scripts but worth knowing: service agents are
provisioned just-in-time in GCD, so `10-tofu.sh` creates them explicitly before
the CMEK resources; and mirroring touches two registries with two different
identities, which the credential helper cannot do (`scripts/mirror-images.sh`
builds an isolated `DOCKER_CONFIG`).

About 45 minutes, of which image mirroring is 15 to 20.

### Phase 2: Istio ambient — new position in the chain

```
./scripts/62-istio-allowlists.sh   # generate, via server-side dry-run
./scripts/63-allowlist-install.sh  # TO BE WRITTEN: bucket, org policy,
                                   #   cluster flag, synchroniser
./scripts/64-istio-ambient.sh      # base, istiod, cni, ztunnel, waypoint
./scripts/66-istio-health.sh       # 10 checks, must be 10/10
```

The cluster update inside `63` takes about 20 minutes on its own, and the first
attempt will be refused with `CUSTOM_ORG_POLICY_DENIED` if the org policy was
only just written. `63` must wait and retry rather than fail.

`64` must enrol namespaces that do not exist yet, so either it tolerates missing
namespaces or enrolment moves to a later step. Cleaner: have each platform
script label its own namespace at creation, and drop the enrolment loop from
`64`.

### Phase 3: platform

```
./scripts/30-keycloak.sh           # the single OIDC issuer, + external LB
./scripts/40-kagent.sh             # + istioAuthzTranslation.enabled=true
./scripts/45-telemetry.sh          # ClickHouse + OTel + Enterprise UI
./scripts/50-agentregistry.sh      # against Cloud SQL over PSC
./scripts/70-agentgateway.sh       # enterprise agentgateway, standalone path
./scripts/80-ingress.sh            # Gateway, routes, private DNS, + external LB
./scripts/85-edge.sh               # Tier 1 regional ALB, Cloud Armor, TLS
```

About 30 minutes.

### Phase 4: workloads and policy

```
./scripts/60-model.sh              # REWRITE FIRST: Qwen on llama.cpp, not Gemma
./scripts/90-mcp-agent.sh          # MCP server + agent, standalone path
./scripts/95-authz-on.sh           # tool-level authz at the gateway
./scripts/56-ar-push-agent.sh      # publish to the catalogue, deploy via registry
./scripts/67-accesspolicy-setup.sh # TO BE WRITTEN: agents ns, waypoint MCPServer,
                                   #   Agent, AccessPolicy, companion policy
```

Model pull is the slow part, roughly 10 minutes for the GGUF.

### Phase 5: verification

```
./scripts/66-istio-health.sh        # ambient L4 + L7          expect 10/10
./scripts/69-accesspolicy-health.sh # three agent paths        expect 9/9
./scripts/68-agent-mesh-policies.sh # bypass prevention        never yet run
```

If all three pass, the rebuild is genuinely equivalent to what we have now, and
better, because it will have been produced by scripts rather than by hand.

---

## Time and session budget

| Phase | Wall clock |
|---|---|
| Teardown | 40 min |
| Close scripting gaps | half a day |
| Phase 0 to 1 | 45 min |
| Phase 2, Istio | 35 min, 20 of it one cluster update |
| Phase 3, platform | 30 min |
| Phase 4, workloads | 20 min |
| Phase 5, verification | 10 min |

**Roughly 2 hours 20 minutes of standup**, and GCD sessions expire in about 45
minutes with no service-account path for a human principal. So expect **three or
four re-authentications** during a rebuild. Every script already calls
`assert_kube_reachable`, which names session expiry rather than reporting a
missing resource, but a long unattended run is not possible in this environment.

That is itself worth recording as a finding: **GCD cannot be provisioned
unattended.** It is already item 4 in the status email to Google.

---

## Risks, and what I would do about them

**The chain has never run from empty.** Highest risk by far. Everything else on
this list is a detail. Mitigation: run it against a *second* project or a second
cluster in the same project before destroying what works. The org policy and the
allowlist bucket are shareable, so a second cluster is cheap to try.

**C3 CPU quota is 24 vCPU with 20 in use.** A second cluster alongside the
current one will not fit. Either raise the quota first, which needs the support
path that requires an Assured Workloads folder in public GCP, or accept
destroying before rebuilding and lose the ability to compare.

**The org policy is organisation-wide.** Getting it wrong affects every cluster
in the org, not just Autopilot ones. Setting `allowAnyGKEPath: false` by accident
would break cluster creation org-wide. `63` should refuse to write a policy that
does not include `allowAnyGKEPath: true`.

**Allowlists are coupled to Helm values and to the Istio version.** Regenerate,
never hand-edit. `62` and `64` already share variables and `64` asserts they
agree on `cniBinDir`; extend that assertion to the AppArmor flag too.

**Two agent topologies now coexist**, standalone gateway and waypoint. They are
not interchangeable and the rebuild must produce both, because the standalone
path is what works with no mesh and is the fallback story for a customer who
cannot use allowlisting.

**`prevent_destroy` on the KMS keys will stop a naive destroy.** Not a problem if
the keys are kept deliberately. It is a problem if someone assumes
`tofu destroy` is total and then hunts for what refused.

---

## What I would change while rebuilding, rather than reproducing faithfully

1. ~~**Org policy on a directory prefix**~~ — **tested, and it does not work.**
   Google's docs say the constraint takes "file or directory paths", but the
   AllowlistSynchronizer admission check compares paths by exact string
   membership and refuses objects under an authorised directory. Every allowlist
   object must be named individually in both the org policy and the cluster
   flag, so an Istio version bump costs a policy edit and another ~20 minute
   cluster update, and no bucket layout avoids it. Written up in
   `feedback/google/evidence/berlin-allowlist-path-prefix-not-honoured-2026-09-04.txt`.
2. **Namespaces labelled for ambient at creation**, by the script that creates
   them, instead of a retroactive enrolment loop.
3. **`60-model.sh` rewritten to what actually runs**, with the Gemma and GPU path
   kept as an unselected profile for when the H100 is unblocked.
4. **One orchestrator** (`run-all.sh`) that runs the phases in order, checks
   session validity between them, and stops cleanly on expiry with a resume
   hint. The chain is currently 27 scripts a human runs in the right order from
   a README.
5. **Fold the two external LoadBalancers into their owning scripts** behind a
   single `EXPOSE_EXTERNAL=1` flag, so laptop access is a deliberate choice
   rather than something done by hand at demo time.
