# kagent 1.0 on Agent Substrate, with gVisor, on Google Cloud Dedicated

Started 2026-10-21. The Berlin cluster (`agentic`, `eu0:soloio-eval`) was
torn down and rebuilt for this lab. It replaces the 2026-09 platform on that
cluster: no Istio, no AgentRegistry, no Keycloak, and **no GPUs**.

**Overview:** [`docs/kagent-substrate-on-gcd.md`](../../docs/kagent-substrate-on-gcd.md)
is the one-page summary: the allowlists GKE needed and why, every test with its
result and evidence, and every file needed to deploy this, inline.

What runs now:

| Layer | Version | Notes |
|---|---|---|
| GKE Autopilot | 1.36.4-gke.1391000, RAPID | the newest Berlin offers; certificate beta APIs enabled at creation |
| kagent (OSS) | 1.0.0-alpha16 | kagent-enterprise is still 0.5.x and has no Substrate runtime |
| Agent Substrate | 0.6.0-alpha3 | pinned by kagent's `go.mod`; gVisor sandbox class |
| Solo Enterprise for agentgateway | v2026.10.0 | the latest; previous lab ran v2026.9.3 |
| Model | OpenAI `gpt-4.1-mini` via agentgateway, over Cloud NAT | key held only by agentgateway |
| Actor snapshots | Cloud Storage `gs://agentic-ate-snapshots`, `u-germany-northeast1` | since 2026-10-21 17:34Z; Workload Identity, no keys; RustFS before that |

## How kagent 1.0 runs an agent

kagent 1.0 is a rewrite. An `Agent` pairs portable behaviour (an
`AgentTemplate`, or an inline one) with a `Harness` that says how it runs. The
controller compiles each revision into a Substrate **ActorTemplate**; Substrate
boots a golden actor on a gVisor worker and snapshots it. Every conversation (a
`Session`) is then an **actor** restored from that snapshot, routed to by
Substrate's network, and suspended back to the snapshot store when idle.
Standalone `Sandbox`es are actors too. Substrate multiplexes many actors onto a
few worker pods; each actor is its own gVisor (`runsc`) sandbox.

```
kagent controller ──gRPC──▶ ate-api ──▶ ate-controller ──▶ worker pods (gVisor)
      │  A2A                                          ▲          │ each actor = runsc sandbox
      └──────────▶ atenet-router ─────────────────────┘          │
                                                                 ▼ egress (policy-checked)
                                         atenet-egress ──▶ agentgateway ──▶ OpenAI
```

State: PostgreSQL in-cluster (kagent and Substrate schemas, logins by Pod
Certificate, no passwords) and Cloud Storage for actor snapshots.

**Where idle actors go.** A suspended actor is a snapshot in the Cloud Storage
bucket `agentic-ate-snapshots` (made by `scripts/35-gcs.sh`): conversations
under `gs://agentic-ate-snapshots/kagent/`, sandboxes under
`gs://agentic-ate-snapshots/sandboxes/` (the `snapshotPolicy` in
`yaml/agents.yaml` and `yaml/egress.yaml`), each as a few small objects under
`…/atespaces/kagent/actors/<actor uid>/snapshots/<uuid>/`, and golden and
checkpoint tags under `…/atespaces/kagent/tags/`. kagent's templates use
`SNAPSHOT_FIDELITY_VOLUMES`, so only the actor's DurableDir volume (`/data`,
which holds the conversation's `sessions.db`) is captured, not memory or the
rest of the root filesystem; a resume boots from the template's golden tag and
restores `/data`. Suspend keeps a node-local copy in `/var/lib/ate` (atelet) and
uploads it; an actor resuming on another node downloads it from GCS. Each
actor keeps only its latest snapshot, and deleting a session deletes its
objects. Metadata (actors, tags, assignments) lives in PostgreSQL. Until
2026-10-21 17:34Z snapshots were in the chart's default, an in-cluster RustFS on
a 10 GiB Hyperdisk claim, which did not outlive the cluster.

## What GCD forced, and how each was solved

1. **Autopilot only.** GKE Warden refused both privileged Substrate workloads
   (verbatim refusals were captured on 2026-10-21):
   - `atelet` DaemonSet: `autogke-no-write-mode-hostpath`, for writable hostPaths
     `/var/lib/ate`, `/var/lib/kubelet/plugins`, `/var/lib/kubelet/device-plugins`
     and for `/dev` (only `/var/log/` is allowed);
   - gVisor worker Deployment: `autogke-default-linux-capabilities`, for
     `NET_ADMIN` and `SYS_ADMIN`, and `autogke-no-write-mode-hostpath` for
     `/var/lib/ate`.
   Warden did not object to the rest of what they request (root, atelet's
   hostPort, `SYS_PTRACE` and the other worker capabilities, Unconfined seccomp
   and AppArmor). Both are admitted by **WorkloadAllowlists** generated from the exact pod specs
   (`scripts/20-allowlists.sh`), the mechanism first proven here for Istio
   (`docs/istio-ambient-on-gcd-autopilot.md`). Everything else in Substrate,
   kagent and agentgateway passes Autopilot unaided (every chart was rendered
   and audited).
2. **Certificate APIs.** Substrate needs `PodCertificateRequest` and
   `ClusterTrustBundle`: GA on 1.37, beta on 1.36. Berlin's newest is 1.36.4, so
   the cluster is created with both beta APIs (`k8s_beta_apis` in the tofu
   profile). GKE honours this only at creation.
3. **Allowlist paths are exact and fixed at creation.** The org policy and the
   cluster's `autopilot_privileged_admission` list each object path; adding one
   later costs an org-policy edit and a ~20 minute cluster update. The atelet and
   worker paths, plus two authorised spares, were set before the cluster was
   created.
4. **Hyperdisk Balanced's 4 GiB floor.** `kagent install` creates its PostgreSQL
   with a 500Mi claim, which can never provision here. A
   `MutatingAdmissionPolicy` (`yaml/pvc-floor.yaml`, GA in 1.36) raises claims to
   the floor at creation and turns a later shrink into a no-op, so re-running the
   installer stays idempotent.
5. **No GPUs, enforced.** The old cluster ran an `a3-edgegpu-8g-nolssd` (H100)
   node around the clock. A `ValidatingAdmissionPolicy` (`yaml/gpu-guard.yaml`)
   refuses any workload that requests accelerators or selects accelerator nodes.
   The project's GPU quota is untouched.
6. **Autopilot's CPU minimum breaks Substrate upgrades.** Autopilot stored the
   chart's RustFS bucket Job with a 50m CPU request instead of 10m, so every
   later `helm upgrade` of the release, a re-run of `kagent install` included,
   failed with "spec.template: ... field is immutable" on the completed Job.
   `yaml/substrate-values.yaml` set `rustfs.bucketInit.resources` to exactly
   what Autopilot stores, and the upgrade then applied cleanly. This no longer
   arises: RustFS is not installed since snapshots moved to Cloud Storage (7).
7. **Snapshots in Cloud Storage.** GCS is Substrate's native backend and needs
   three things on GCD. Credentials: the object-store plugin sidecars (atelet,
   ate-api-server) use the pod's Workload Identity, and `35-gcs.sh` grants
   `roles/storage.objectUser` on the bucket to `ate-system/atelet` and
   `ate-system/ate-api-server` as direct principals; no Google service account,
   and service-account keys are forbidden by the org policy anyway. The
   universe: the plugin's Go client defaults to `storage.googleapis.com`, so
   `objectStorePlugin.extraEnv` sets `GOOGLE_CLOUD_UNIVERSE_DOMAIN`. The
   allowlist: that env var is new on atelet's sidecar, so the atelet
   WorkloadAllowlist was regenerated (`20-allowlists.sh atelet`) at its existing
   path. `rustfs.enabled: false` and `atelet.storageBackend: gcs` do the rest.

## Running it

The cluster is OpenTofu (`infra/tofu`, profile `gcd-autopilot`); see the header
of `scripts/10-cluster.sh` for the replace command. Then:

```bash
./scripts/run-all.sh        # 10 → 15 → 20 atelet → 30 → 35 → 40 (+20 worker) → 50 → 60 → 70 → 75
```

| Script | Does |
|---|---|
| `10-cluster.sh` | credentials into an isolated kubeconfig; proves the certificate APIs are served |
| `15-gpu-guard.sh` | applies the GPU admission policy and proves it refuses an H100 pod |
| `20-allowlists.sh atelet\|worker` | generates, uploads and installs the two WorkloadAllowlists |
| `30-agentgateway.sh` | agentgateway Enterprise, ClusterIP Gateway, OpenAI backend; proves a call with a placeholder key |
| `35-gcs.sh` | the snapshot bucket `agentic-ate-snapshots` and its Workload Identity grants for atelet and ate-api-server |
| `40-kagent.sh` | PVC floor policy, `kagent install` (Substrate, Pod Certificates, PostgreSQL, kagent), worker allowlist, the `ate-operator` account |
| `50-agents.sh` | Harness, two agents and a sandbox template; waits for golden snapshots |
| `60-verify.sh` | end-to-end checks; writes `evidence/verify-*.txt` |
| `70-substrate-behaviours.sh [api\|multiplex\|fork\|egress\|all]` | Substrate's API through `kubectl ate`, 20 concurrent conversations in two rounds, checkpoint and fork, EgressPolicy deny/allow; writes `evidence/behaviours-*.txt` and `evidence/multiplex-*/` |
| `75-gcs-roundtrip.sh` | one conversation suspended to GCS, its worker deleted, resumed and loaded from GCS on another node; keeps the session; writes `evidence/gcs-roundtrip-*.txt` |
| `kagent_mcp.py` | minimal client for kagent's MCP server (checkpoints and forks have no CLI command) |
| `actor_timeline.py` | turns a multiplexing run's raw samples and logs into its `report.txt` |

Secrets come from `~/code/solo/secrets/secrets-envs.sh` (`AGENTGATEWAY_LICENSE_KEY`,
`OPENAI_API_KEY`) and are never written to the repo.

Using it:

```bash
export KUBECONFIG=$PWD/deploy/.kubeconfig
kubectl -n kagent port-forward svc/kagent-ui 8080:8080 &           # UI: http://localhost:8080
# CLI/API on any free local port. Not 8083: it is the kagent CLI's default URL,
# and a local server or stale forward there makes the CLI talk to it, silently.
PORT=28083
kubectl -n kagent port-forward svc/kagent-controller $PORT:8083 &
kagent() { ~/.cache/kagent/1.0.0-alpha16/kagent --api-url http://127.0.0.1:$PORT --gateway-url http://127.0.0.1:$PORT "$@"; }
SID=$(kagent agent session create --agent trustusbank-assistant -o json | jq -r .session.id)
kagent agent invoke --session "$SID" --task "Hello"
kagent sandbox create trustusbank-scratch --request-id demo-1
kagent sandbox exec <id> -- sh -c 'uname -sr; dmesg | head'

# Substrate's own API, as the ate-operator principal (kubectl-ate is built by
# scripts/lib.sh ate_cli into ~/.cache/kagent-substrate-lab/substrate-0.6.0-alpha3/)
kubectl -n ate-system create token ate-operator --audience api.ate-system.svc --duration 30m > op.token
kubectl ate --token-file op.token get actors -A

# Suspended actors' snapshots, in Cloud Storage
gcloud storage ls -r gs://agentic-ate-snapshots/kagent/atespaces/kagent/actors/
```

## Verification

See the latest `evidence/verify-*.txt`. Results are summarised in
[Results](#results) below.

## Results

2026-10-21, `scripts/60-verify.sh`: **13 passed, 0 failed**
(`evidence/verify-2026-10-21T1515Z.txt`; actor evidence in
`evidence/gvisor-actors-2026-10-21.txt`).

| Check | Result |
|---|---|
| Substrate control plane (ate-api, controller, idp, router, egress, credential provider, RustFS) | all available |
| atelet on every node, admitted by its WorkloadAllowlist | 4/4 |
| gVisor worker pods (WorkerPool `kagent-default`, class `gvisor`) | 2/2, `autopilot.gke.io/no-connect: true` |
| H100 pod / GPU Deployment | refused by `deny-gpu-workloads` |
| Agent conversation: Substrate actor → agentgateway → OpenAI | `trustusbank-assistant` answered; agentgateway logged the completion |
| Standalone sandbox kernel | `uname`: **`Linux 4.19.0-gvisor`**; `dmesg`: **`Starting gVisor...`**; node kernel `6.12.105+` (COS) |
| Suspend → resume | file written before suspend read back after resume (snapshot to RustFS and restore) |
| Agent drives a sandbox through kagent's MCP tools | `trustusbank-sandbox-ops` created a sandbox, ran `uname -sr && dmesg`, reported `Linux 4.19.0-gvisor` |

The workers' own logs show a `runsc` launch for every actor, including each
agent conversation (`session-…` actors), and checkpoint RPCs when sessions go
idle. Agents became Ready (golden actor booted and snapshotted) about 20 seconds
after `kubectl apply`.

agentgateway was proven separately (`30-agentgateway.sh`): an in-cluster call
with a placeholder key returned HTTP 200 from `gpt-4.1-mini`, so the gateway
injected the real key.

Re-run at 2026-10-21T15:54Z, 40 minutes later: 13 passed again
(`evidence/verify-2026-10-21T1554Z.txt`).

**Substrate's own records** (`evidence/substrate-records-2026-10-21.txt`, read
from its PostgreSQL schema): 1 atespace (`kagent`); 4 ActorTemplates, one per
prepared revision (the sandbox template, the assistant, and two for sandbox-ops,
whose prompt edit made a new revision while the old one is retained); 4 snapshot
tags; 2 registered workers; 6 session actors and **no worker assignments**, so
every conversation actor had been suspended to its snapshot once idle. Query:

```bash
kubectl -n kagent exec deploy/kagent-postgresql -c postgresql -- \
  psql -U postgres -d kagent -c 'select atespace, name from substrate.actor_templates'
```

### Substrate behaviours (2026-10-21, 16:00–16:40Z)

`scripts/70-substrate-behaviours.sh all`: **22 passed, 0 failed**, twice
(`evidence/behaviours-2026-10-21T1619Z.txt`, and `…T1635Z.txt` after `kagent
install` had been re-run over the live install: `evidence/reinstall-2026-10-21.txt`).
`60-verify.sh` passed 13/13 again in between (`evidence/verify-2026-10-21T1622Z.txt`).

| Behaviour | Result | Evidence |
|---|---|---|
| Substrate's API (`kubectl ate`, built from tag `v0.6.0-alpha3`) | the shared `ate-client` identity and a kagent-controller token are refused (`PermissionDenied`: the owner is the controller's Pod Certificate SPIFFE ID, a token authenticates as `system:serviceaccount:…`). With the added `ate-operator` bootstrap owner: atespaces, actor templates, actors with state, tags and workers listed | `substrate-api-2026-10-21.txt` |
| Multiplexing, 20 conversations at once, two rounds (three runs) | 20 actors, at most 8 running (4 per worker: each actor reserves 1 CPU of the worker's 4; `kubectl ate get workers` at the peak: `4/1000` actors, `4/4` CPU each); all 40 invocations answered in every run; Substrate resume p50 343–357 ms, p95 446–531 ms, max 582 ms | `multiplex-2026-10-21T1635Z/report.txt`, `…T1619Z`, `…T1613Z` |
| No worker has room | 17–20 of 57–60 calls per run refused at resume and answered UNAVAILABLE at once (no parking); kagent's gateway marks them not accepted and the kagent CLI re-sends them, so nothing failed | same |
| Actor resumes on another worker | 5, 7 and 10 actors (three runs) came back on the other worker in round 2, each continuing its own conversation | same |
| Checkpoint and fork (kagent MCP tools) | the fork recalls only what preceded the checkpoint; the original keeps both turns; the checkpoint is an atespace-scoped Substrate tag | `checkpoint-fork-2026-10-21.txt` |
| EgressPolicy | no policy: names do not resolve, an IP literal gets 403 from atenet-egress; granting `https://example.com` on the SandboxTemplate opens it in the running sandbox, `api.github.com` stays closed | `behaviours-*.txt` |
| Re-running `kagent install` | clean on the first attempt, twice; operator principal kept; atelet unchanged | `reinstall-2026-10-21.txt` |
| microVM class | not attempted: Autopilot has no nested virtualisation | — |

### Snapshots on Cloud Storage (2026-10-21, 17:34–17:47Z)

Switched with `35-gcs.sh`, `20-allowlists.sh atelet`, a `helm upgrade` of the
Substrate release (revision 6; RustFS and its claim removed) and a re-apply of
`yaml/agents.yaml` and `yaml/egress.yaml`, after which every template's golden
snapshot was written to GCS within a minute.

| Check | Result | Evidence |
|---|---|---|
| `60-verify.sh` | 13 passed, 0 failed | `verify-2026-10-21T1737Z.txt` |
| Multiplexing, 20 conversations, two rounds | all 40 answered; 8 actors resumed on the other worker's node, so from GCS; resume p50 383 ms, p95 555 ms, max 620 ms (RustFS: p50 343–357 ms) | `multiplex-2026-10-21T1738Z/report.txt` |
| One conversation, its worker deleted between turns (`75-gcs-roundtrip.sh`) | snapshot of 5 objects in GCS; resumed on the other node, whose object-store plugin downloaded the 4 snapshot files; the code word recalled | `gcs-roundtrip-2026-10-21T1744Z.txt` |
| Checkpoint and fork | 4 passed: a checkpoint is a tag in GCS, and the fork restores from it | `behaviours-2026-10-21T1746Z.txt` |

Not re-run on GCS: the API, EgressPolicy and reinstall checks, which do not touch
snapshot storage.

## Open items

Decisions left with the user:

- The project's GPU quota was deliberately left alone (it took a Google support
  case to get); GPU workloads are refused at admission instead.
- Images are pulled from public registries over Cloud NAT, not mirrored into the
  in-universe Artifact Registry. Mirroring needs atelet's image credential
  provider (two more host mounts, so a regenerated allowlist).
- Committed and pushed on branch `trustusbank-agent-names` up to 64d8c7c, not
  merged to `main`; the switch to Cloud Storage is not committed yet. The
  user's own pending edits in `poc/2026-09-agentic-platform` remain uncommitted.
- The 11 conversations suspended before the switch point at RustFS snapshots
  that no longer exist, so they cannot resume. They were test sessions; delete
  them with `kagent agent session delete <id>`.
- The snapshot bucket uses Google-managed encryption; the 2026-09 platform's
  buckets used CMEK, which works for Cloud Storage here if wanted.
- The GPU guard (`15-gpu-guard.sh`) still runs here and is applied on the
  cluster; the overview page no longer mentions it. Whether to drop it from the
  lab is the user's call.
- The repository is public; the old console password (`solo` user) in
  README/TASKS/DEMO-READINESS and the default in `deploy_google_console.py` have
  been public since 2026-10-02. Rotating or removing it is the user's call.

### Found on the way

- **The AllowlistSynchronizer re-reads files only when its spec changes.** A
  file re-uploaded to an already-listed path stayed unsynced for over 7 minutes,
  then installed within 5 seconds of the path list changing.
  `20-allowlists.sh sync` flips the list order when it is otherwise unchanged.
  This corrects the 2026-09 Istio write-up, which says re-uploading is enough.
- **Warden's generated allowlist arrives only in the refusing client's error.**
  For a Deployment created by a controller, that is the controller's log; the
  WorkerPool template carries `cloud.google.com/generate-allowlist: "true"` so the
  refusal includes it.
- **Warden's regenerated allowlist kept the old env names.** Asked again for
  atelet with the GCS settings, Warden returned an allowlist listing both the
  new `GOOGLE_CLOUD_UNIVERSE_DOMAIN` and the five RustFS `AWS_*` variables the
  new spec no longer has, so it admits both configurations.
- **The multiplexing test leaves no snapshots behind.** It deletes its 20
  sessions, and deleting a session deletes its snapshot objects; that is why
  only kept sessions show up in the bucket.
- **`kagent install`'s 500Mi PostgreSQL claim cannot provision on GCD**
  (Hyperdisk Balanced floor, 4 GiB): see `yaml/pvc-floor.yaml`. Worth raising
  with kagent: the size should be configurable.
- **`kubectl ate` needs a principal `kagent install` does not create.** Substrate
  authorises its API through OpenFGA bootstrap owners, and kagent's installer
  names only its controller's SPIFFE ID. `yaml/substrate-values.yaml` adds
  `system:serviceaccount:ate-system:ate-operator` (a values file replaces the
  list, so the controller is repeated); the shared `ate-client` fallback stays
  out, as Substrate's own docs advise outside development.
- **Capacity is CPU, not actor count.** A worker advertises room for 1000
  actors, but each running actor reserves its limits (1 CPU / 1 GiB) from the
  worker pod's (4 CPU / 8 GiB). Idle actors suspended within seconds.
- **0.6.0-alpha3's atenet-router (agentgateway-based) does not park requests**
  when no worker has room, unlike Substrate's request-parking design for the
  Envoy router: it answers UNAVAILABLE at once. kagent's gateway turns that into
  `KAGENT_SEND_NOT_ACCEPTED` (retry after 100 ms) and the kagent CLI retries for
  up to 30 s; any other A2A client of kagent must do the same.
- **Sandbox egress is closed twice over**: unlisted names do not resolve (the
  sandbox's DNS server and only route is `169.254.17.1`), and IP literals meet
  the egress gateway (403, or a failed TLS handshake without SNI).
- **The 2026-10-01 probe misreported two results.** `20-cluster-probes.sh` 0.3
  ("pull from ghcr.io FAILED") actually pulled the image and failed on `exec sh`
  in a distroless image; 0.6 ("StatefulSet+PVC REJECTED") was admitted, and an
  unrelated error set the exit status. Public registries are reachable over
  Cloud NAT, and StatefulSets with Hyperdisk claims work.

## Operational notes

- **No exec or port-forward into allowlisted pods.** GKE stamps
  `autopilot.gke.io/no-connect: "true"` on pods admitted by a WorkloadAllowlist,
  so atelet and the workers cannot be exec'd into. `kubectl logs` works.
- **Substrate's state is readable three ways**: `kubectl ate` as `ate-operator`
  (see Using it), the PostgreSQL schema `substrate` (query above), and
  ate-api-server's "Actor state changed" log lines, which time every transition
  (split across its two replicas: read both).
- **Changing Substrate's values**: `helm upgrade substrate
  oci://ghcr.io/kagent-dev/substrate/helm/substrate --version 0.6.0-alpha3 -n
  ate-system --reuse-values -f yaml/substrate-values.yaml`. Diff `helm template`
  first: if the atelet DaemonSet changes, its allowlist must be regenerated.
- **Allowlists pin images.** Bumping Substrate means regenerating both
  allowlists, at new paths (the version is in the path), which must first be
  added to the org policy and the cluster.
- **Substrate's CAs last a year** and nothing renews them (kagent docs). Re-run
  per the kagent Helm README before 2027-10-21.
- **Images are pulled from public registries over Cloud NAT** (ghcr.io, Docker
  Hub, registry.k8s.io; the gVisor runtime from `gs://gvisor` anonymously).
  Mirroring into the in-universe Artifact Registry would need atelet's image
  credential provider (two more hostPath mounts in its allowlist).
