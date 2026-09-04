# gke-standard — not yet implemented (Track A)

Placeholder. This is the module where Istio ambient is possible: a GKE
**Standard** cluster on public GCP, with a node pool we control, so
`istio-cni` (hostNetwork + `SYS_ADMIN`) and `ztunnel`
(`SYS_ADMIN` / `NET_ADMIN` / `runAsUser: 0`) can actually schedule.

It does not belong on GCD and never will: GCD is Autopilot-only, Autopilot
rejects those DaemonSets, and GCD additionally does not support the
`WorkloadAllowlist` mechanism that would be the only way to grant them.

Build this when we do Track A. See `poc/2026-09-agentic-platform/PLAN.md`.
