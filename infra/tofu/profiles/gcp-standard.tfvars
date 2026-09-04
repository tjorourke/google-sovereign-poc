# Track A: public GCP, GKE Standard. Deferred, kept so the shape is obvious.
#
# This is the profile where Istio ambient actually works, and the A-minus-B
# delta is the feedback deliverable for Google. The gke-standard module is not
# written yet; `tofu apply` with this profile currently builds network +
# registry and no cluster.
profile = "gcp-standard"

universe_api_domain      = "" # empty = public GCP
artifact_registry_domain = "pkg.dev"
project_id               = "REPLACE-ME"
project_short            = "REPLACE-ME"
project_number           = "REPLACE-ME"
region                   = "europe-west3"

cluster_name    = "agentic-std"
release_channel = "REGULAR"

enable_cloudsql    = false
enable_private_dns = false
