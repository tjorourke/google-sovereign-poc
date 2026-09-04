# Cloud Storage. GCD constraints (/storage/docs/tpc-differences):
#   - single-region buckets only; no dual-region, no multi-region, no relocation
#   - LOCATION IS MANDATORY. There is no default location, unlike public GCP.
#   - no Storage Transfer Service, no Storage Insights, no Rapid Cache
#   - no domain-named buckets, no custom-domain serving
#   - service-account HMAC keys only (no user-account HMAC)
#   - no regional or locational endpoints
#
# The CMEK on these buckets needs the Cloud Storage service agent to already
# hold cryptoKeyEncrypterDecrypter on the key. Service agents in GCD are
# provisioned JUST-IN-TIME, not on API enable, so 10-tofu.sh creates them
# explicitly before this module applies. If you see a 400 about the key, that
# is the missing agent, not a bad key.

locals {
  buckets = {
    weights  = "model weights (Gemma), mounted via the Cloud Storage FUSE CSI driver"
    artefact = "MCP server and agent build artefacts"
    archive  = "exported traces and audit archive"

    # Autopilot privileged-workload allowlists (WorkloadAllowlist YAML), read by
    # the AllowlistSynchronizer. The GKE service agent needs storage.admin on
    # this bucket or the synchroniser reports an error that looks like a policy
    # problem. See docs/istio-ambient-allowlist-plan.md.
    allowlist = "Autopilot WorkloadAllowlist files for privileged workloads"
  }
}

resource "google_storage_bucket" "this" {
  for_each = local.buckets

  name     = "${var.name_prefix}-${each.key}"
  location = var.region # mandatory in GCD
  labels   = merge(var.labels, { content = each.key })

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # POC

  encryption {
    default_kms_key_name = var.kms_key_id
  }

  versioning {
    enabled = true
  }
}

# The AllowlistSynchronizer reads the allowlist files as the GKE service agent,
# not as the caller, so the agent needs access to this bucket specifically.
# Google's own how-to asks for storage.admin here.
resource "google_storage_bucket_iam_member" "allowlist_gke_agent" {
  count = var.gke_service_agent == "" ? 0 : 1

  bucket = google_storage_bucket.this["allowlist"].name
  role   = "roles/storage.admin"
  member = "serviceAccount:${var.gke_service_agent}"
}
