# Solo.io on Google Cloud Dedicated (Berlin)

Infrastructure, reference architectures and findings for Solo.io's evaluation of
**Google Cloud Dedicated** in Germany — a separate, partner-operated cloud
universe, not a GCP region.

Everything here runs in the `berlin` preview universe
(`apis-berlin-build0.goog`, region `u-germany-northeast1`, project
`eu0:soloio-eval`). Nothing about `console.cloud.google.com` or `googleapis.com`
applies. See `CLAUDE.md` for the environment constants and the constraints that
shape every decision in this repo.

**What is deployed:** a GKE Autopilot cluster running **Solo Enterprise for
Istio** in ambient mode, **Solo Enterprise for kagent**, **enterprise
agentgateway**, **AgentRegistry**, Keycloak as the single OIDC issuer, a
self-hosted model, TLS on every browser-facing URL, and a Prometheus/Grafana
stack. All Enterprise builds; no OSS components.

---

## Quick start

Four commands, in order. The middle one takes about 75 minutes.

```bash
cp .env.local.example .env.local     # then edit: it is gitignored
./scripts/gcd-auth.sh                # sign in to the universe (browser)
./scripts/deploy-e2e.sh              # the whole stack, 23 phases
./scripts/teardown.sh                # cluster only; Cloud SQL and the VPC survive
```

Re-running `deploy-e2e.sh` is safe: it records completed phases and resumes.

### Prerequisites

- `gcloud` (a recent build — `universe_domain` support is mandatory)
- `tofu`, `kubectl`, `helm`, `docker`, `jq`, `python3`, `openssl`
- Licence keys for every Solo Enterprise component, in a file outside this repo.
  The default location is `~/code/solo/secrets/secrets-envs.sh`; override with
  `SOLO_SECRETS_FILE`. Needed: `SOLO_LICENSE_KEY`, `AGENTGATEWAY_LICENSE_KEY`,
  `SOLO_ISTIO_LICENSE_KEY`.

### Authentication, and the one thing that will catch you

GCD has no Google Accounts. Identity comes only from Workforce Identity
Federation, which means a **browser sign-in**, and org policy blocks
service-account keys — so there is no unattended auth path at all
(`feedback/google/07`).

**`gcloud auth login` ending on a "Login successful" page means you
authenticated against public GCP, not GCD. A 404 in the browser is the correct
outcome.**

Access tokens last under an hour and refresh tokens expire after a few days, so
a long deployment can outlive its credential. Two helpers exist for that:

```bash
./scripts/gcd-session.sh status      # is the session alive, and for how long
./scripts/gcd-auth-assist.sh start   # sign in ONCE in a dedicated browser
./scripts/gcd-auth-assist.sh login   # thereafter re-mint without clicking
```

`gcd-auth-assist.sh` is a **lab convenience only** — it drives a browser you
have already signed into. It is deliberately not part of `deploy-e2e.sh`,
because re-authentication is an artifact of this preview and has no place in a
deployment script.

---

## Repository layout

```
infra/tofu/        OpenTofu: network, Autopilot cluster, Cloud SQL, KMS, buckets
infra/helm/        chart list and the generated image manifest
infra/bootstrap/   gcloud + WIF setup, org policy, project creation
poc/               time-boxed labs, date-prefixed and disposable
docs/              customer-facing material and technical write-ups
feedback/google/   numbered findings handed to Google — the main deliverable
scripts/           top-level entry points, described below
```

---

## The scripts

### Top level — start here

| Script | What it does |
|---|---|
| `deploy-e2e.sh` | **The main entry point.** Stands the whole stack up, 23 phases, resumable. `--fresh` forgets phase state, `--recreate` replaces the cluster first. |
| `teardown.sh` | Destroys the cluster and its Workload Identity bindings. Keeps Cloud SQL, KMS, the VPC, buckets and the DNS zone. `--all` destroys those too, `--dry-run` shows the plan. |
| `gcd-auth.sh` | Interactive sign-in to the universe. Does CLI credentials **and** ADC — Terraform needs the second. |
| `gcd-auth-assist.sh` | `start` / `login` / `status` / `stop`. Re-mints credentials without clicking, by reusing a browser you signed into once. Lab only. |
| `gcd-session.sh` | `status` or `hold` — is the session alive, how long is left. |
| `lab-unattended.sh` | Runs `deploy-e2e.sh` and restarts it across credential expiry. Lab only; takes the same flags. |
| `mirror-images.sh` | Copies every image in `infra/helm/images.txt` into the in-universe registry. GCD cannot reach `ghcr.io` or `pkg.dev`, so nothing installs without this. |
| `derive-images.sh` | Regenerates `infra/helm/images.txt` by rendering every chart. Edit `infra/helm/charts.txt` and re-run; never hand-edit the image list. |
| `gcd-docs.sh` | Fetches a page from Google's Berlin doc set, which is gated behind an HTTP header rather than a login. |
| `computeclass-probe.sh` | Is the `ComputeClass` CRD served, and will a GPU pod schedule? Written for the open GPU case with Google. |

### The deployment chain

`deploy-e2e.sh` calls `poc/2026-09-agentic-platform/scripts/run-all.sh`, which
runs these in order. Each is independently runnable, and the chain records what
completed so a re-run resumes rather than repeats.

```bash
cd poc/2026-09-agentic-platform
./scripts/run-all.sh                 # continue from wherever it stopped
./scripts/run-all.sh --list          # show every phase and its state
./scripts/run-all.sh --only 64       # run one phase
./scripts/run-all.sh --from 80       # run from this phase onwards
./scripts/run-all.sh --reset         # forget progress, keep the cluster
```

| Phase | Script | What it installs |
|---|---|---|
| 08 | `08-enable-apis.sh` | the APIs a fresh GCD project leaves off |
| 10 | `10-tofu.sh apply` | network, Autopilot cluster, Cloud SQL, KMS, buckets |
| 20 | `20-cluster-probes.sh` | probes that need a live cluster; writes evidence for Google |
| 15 | `15-mirror-images.sh` | mirrors images into the in-universe registry |
| 25 | `25-cluster-baseline.sh` | cert-manager, External Secrets, Prometheus, Grafana |
| 62 | `62-istio-allowlists.sh` | generates the Autopilot `WorkloadAllowlist`s |
| 63 | `63-allowlist-install.sh` | authorises them: bucket, org policy, cluster, synchroniser |
| 64 | `64-istio-ambient.sh` | **Solo Enterprise for Istio**: istiod, istio-cni, ztunnel, waypoint |
| 66 | `66-istio-health.sh` | verifies ambient L4 and L7 enforcement (expect 10/10) |
| 30 | `30-keycloak.sh` | Keycloak, the single OIDC issuer |
| 40 | `40-kagent.sh` | **Solo Enterprise for kagent** |
| 45 | `45-telemetry.sh` | ClickHouse, OTel collector, **Enterprise UI** |
| 50 | `50-agentregistry.sh` | **AgentRegistry** against Cloud SQL over PSC |
| 70 | `70-agentgateway.sh` | **enterprise agentgateway**, standalone path |
| 80 | `80-ingress.sh` | Gateway, HTTPRoutes, private DNS, external LoadBalancer |
| 85 | `85-tls.sh` | TLS on every browser-facing URL, and the https OIDC issuer |
| 60 | `60-model.sh` | self-hosted model inside the sovereign boundary |
| 90 | `90-mcp-agent.sh` | MCP tool server and the first agent |
| 95 | `95-authz-on.sh` | tool-level authorization at the gateway |
| 56 | `56-ar-push-agent.sh` | publishes to the catalogue, deploys via the registry |
| 67 | `67-accesspolicy-setup.sh` | the waypoint path governed by `AccessPolicy` |
| 69 | `69-accesspolicy-health.sh` | verifies all three agent paths (expect 9/9) |
| 97 | `o11y-deploy.sh` | scrapes the Solo stack, loads the Grafana dashboard |

The order is deliberate and not numeric. Two examples of why: **15 runs after 20**
because the probes establish that GCD cannot pull from public registries, which
is what makes mirroring necessary; **97 runs last** because it installs scrape
targets for the Solo components, so they all have to exist first or Prometheus
finds nothing.

### Off-chain helpers

| Script | What it does |
|---|---|
| `00-preflight.sh` | read-only probes that need no cluster |
| `55-arctl-connect.sh` | **source** this, don't run it — exports `arctl` credentials minted in-cluster |
| `57-ar-ask.sh` | ask the AgentRegistry-deployed agent something, and show the tools it called |
| `68-agent-mesh-policies.sh` | puts the real agent flows under ambient policy |
| `85-edge.sh` | applies the Tier 1 edge once agentgateway exists |
| `95-authz-off.sh` | removes MCP tool authorization, back to all tools visible |
| `98-gpu-evidence-capture.sh` | collects live evidence for the GPU case with Google |
| `99-teardown.sh` | in-cluster teardown in reverse dependency order |
| `o11y-deploy.sh` | `install` / `--status` / `--open` / `--remove` |

---

## Verifying a deployment

Four checks, each of which tries to break something rather than assert it works:

```bash
cd poc/2026-09-agentic-platform
./scripts/66-istio-health.sh         # ambient L4 + L7 enforcement      expect 10/10
./scripts/69-accesspolicy-health.sh  # all three agent paths            expect  9/9
./scripts/85-tls.sh --verify         # TLS on all five hostnames        expect  5/5
./scripts/o11y-deploy.sh --status    # scrape targets and metric series
```

### Reaching the consoles

GCD has **no public DNS zone**, so the hostnames do not resolve from a laptop.
`80-ingress.sh` prints an external address and the `/etc/hosts` lines to add:

```
34.3.x.x  keycloak.agentic.eu0.internal
34.3.x.x  kagent.agentic.eu0.internal          <- the Enterprise UI
34.3.x.x  agentregistry.agentic.eu0.internal
34.3.x.x  mcp.agentic.eu0.internal
34.3.x.x  llm.agentic.eu0.internal
```

Certificates come from an in-cluster CA, so trust it or expect browser warnings:

```bash
./scripts/85-tls.sh --ca > /tmp/agentic-ca.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/agentic-ca.crt
```

---

## Labs

| Lab | What it is |
|---|---|
| `poc/2026-09-agentic-platform/` | the platform itself — everything in the table above |
| `poc/2026-09-trustusbank/` | a German bank running SEPA Instant fraud triage across three governed agents. Write-up: `docs/trustusbank-sepa-fraud-triage.md` |

TrustUsBank assumes the platform is already up, and adds only its own namespace:

```bash
cd poc/2026-09-trustusbank
./scripts/deploy.sh                  # MCP servers, agents, policies, A2A edge
./scripts/demo.sh                    # the scenario end to end
./scripts/health.sh                  # attack every control   expect 23/0
```

---

## Things that will cost you a day if nobody tells you

- **Set `universe_domain`, always.** Without it `gcloud` silently talks to public
  GCP and the errors look like broken permissions. Work inside a named `gcloud`
  configuration and confirm with `gcloud config list`.
- **ADC is separate from the CLI credential.** Terraform and the client libraries
  will not pick up `gcloud auth login`. `gcd-auth.sh` does both.
- **The cluster is Autopilot, and Autopilot defaults any unspecified CPU/memory
  request to 500m/2Gi per container** — a real reservation against a 24 vCPU
  quota. Set requests explicitly. See `docs/autopilot-resource-sizing.md`.
- **Do not change `istio-cni` or `ztunnel` resources.** The `WorkloadAllowlist`
  pins the container spec exactly, including `env` and `resources`; change one
  field and the pod is refused admission and ambient stops working.
- **The lab uses its own kubeconfig**, at
  `poc/2026-09-agentic-platform/deploy/.kubeconfig`. `~/.kube/config` is shared
  with every kind cluster on the machine and gets clobbered mid-run. Export
  `KUBECONFIG` to that path before running `kubectl` by hand.
- **GPUs do not schedule yet.** `ComputeClass` needs GKE 1.36 (RAPID), and even
  there the A3/H100 quota metrics do not exist in this universe. Open with
  Google: `feedback/google/gpu-quota-ask.md`.

---

## Feedback to Google

`feedback/google/` is the most valuable output in this repo — numbered,
reproducible findings with verbatim command output, plus the evidence files
behind them. Start with `feedback/google/01-autopilot-ambient-blocker.md` for the
format.
