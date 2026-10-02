#!/usr/bin/env bash
# Reproducible Google-demo overlay after deploy-e2e.sh has installed the platform.
# Requires a live Berlin gcloud session and Gemma. Existing Gemini Secret is reused.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="$ROOT/poc/2026-09-agentic-platform/scripts"
python3 "$SD/61-model-context.py" --apply
bash "$SD/87-vsr-routes.sh"
bash "$SD/88-identity.sh"
# Install JWT verification/budgets without adding illustrative cost history.
bash "$SD/89-cost.sh" enforce
bash "$SD/96-dlp.sh"
python3 "$SD/94-audit-waypoints.py" --apply
python3 "$SD/93-audit-call.py"
