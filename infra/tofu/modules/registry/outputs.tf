output "repo_name" { value = google_artifact_registry_repository.docker.repository_id }
output "location" { value = google_artifact_registry_repository.docker.location }

# Deliberately NOT exporting a composed registry host.
#
# The docs give the AR domain as pkg-berlin-build0.goog, and public GCP prefixes
# it with "<region>-docker", but that prefix is a public-GCP convention and is
# unconfirmed for Berlin. Composing it here would bake a guess into infra/.
# Resolve it at use time from the API, which is authoritative:
#
#   gcloud artifacts repositories describe "$AR_REPO" \
#     --location "$AR_LOCATION" --format='value(registryUri)'
#
# poc/2026-09-agentic-platform/scripts/00-preflight.sh does exactly that and
# warns if it disagrees with AR_HOST in .env.local.
