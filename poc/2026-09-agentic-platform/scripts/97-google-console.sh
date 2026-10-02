#!/usr/bin/env bash
# Google-only hosted console. Base platform + scripts/deploy-google-demo.sh first.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SD/lib.sh"
load_env
require kubectl python3 docker gcloud
assert_universe
exec python3 "$SD/deploy_google_console.py" "$@"
