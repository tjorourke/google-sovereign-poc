# Artifact Registry, Docker format, standard mode.
#
# GCD constraints, from /artifact-registry/docs/tpc-differences:
#   - formats: Docker, Apt, Yum ONLY. No helm format.
#   - standard mode only: no remote and no virtual repositories, therefore NO
#     pull-through mirror. Anything we need must be pushed here explicitly or
#     be pullable over Cloud NAT egress.
#   - no cleanup policies, no GPG keys for Apt/Yum
#   - no Artifact Analysis vulnerability scanning
#   - supported push/pull clients are listed as Docker CLI, crictl, apt, yum.
#     `helm` is NOT on that list, which is the open risk to OCI Helm charts.
resource "google_artifact_registry_repository" "docker" {
  repository_id = var.repo_name
  location      = var.region
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"
  description   = "Solo images and charts for the agentic platform eval"
  labels        = var.labels
  kms_key_name  = var.kms_key_id
}
