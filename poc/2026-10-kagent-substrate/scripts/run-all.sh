#!/usr/bin/env bash
# run-all.sh — the whole lab, in order, once the cluster exists (see 10-cluster.sh
# for the OpenTofu replace that builds it). Every step is idempotent.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$D/10-cluster.sh"
"$D/15-gpu-guard.sh"
"$D/20-allowlists.sh" atelet
"$D/30-agentgateway.sh"
"$D/35-gcs.sh"            # snapshot bucket + Workload Identity grants
"$D/40-kagent.sh"          # runs 20-allowlists.sh worker itself
"$D/50-agents.sh"
"$D/60-verify.sh"
"$D/70-substrate-behaviours.sh"   # Substrate API, multiplexing, fork, EgressPolicy
"$D/75-gcs-roundtrip.sh"      # one conversation persisted to and loaded from GCS
