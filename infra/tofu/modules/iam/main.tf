# One service account per component, each bound to the Kubernetes ServiceAccount
# that uses it via Workload Identity Federation for GKE.
#
# The GCD-specific part is the pool domain. Public GCP uses
#   <project>.svc.id.goog
# GCD uses
#   <project>.eu0.svc.id.goog
# and the IAM principal is
#   principal://iam.googleapis.com/projects/<num>/locations/global/workloadIdentityPools/<pool>/subject/ns/<ns>/sa/<ksa>
# In practice the member string the provider wants is the serviceAccount: form
# below. Note the member string keeps the literal iam.googleapis.com host even
# inside the universe — do NOT rewrite it to .goog.
#
# Also note what IAM here cannot do (/iam/docs/tpc-differences): no principal
# access boundary policies, no Privileged Access Manager, no SCIM for Workforce
# Identity Federation, and NO Policy Intelligence at all — so no Policy
# Troubleshooter to tell you why a permission was denied. Grant carefully.

locals {
  # component => { ns, ksa, roles }
  components = {
    agentregistry = {
      ns    = "agentregistry-system"
      ksa   = "agentregistry"
      roles = ["roles/cloudsql.client", "roles/cloudsql.instanceUser"]
    }
    agentgateway = {
      ns    = "agentgateway-system"
      ksa   = "agentgateway"
      roles = ["roles/logging.logWriter", "roles/monitoring.metricWriter"]
    }
    kagent = {
      ns    = "kagent"
      ksa   = "kagent"
      roles = ["roles/logging.logWriter", "roles/monitoring.metricWriter"]
    }
    model = {
      ns    = "model"
      ksa   = "vllm"
      roles = ["roles/storage.objectViewer"]
    }
    externalsecrets = {
      ns  = "external-secrets"
      ksa = "external-secrets"
      # The whole point: decrypt the envelope-encrypted license keys and LLM
      # credentials, because GCD has no Secret Manager to read them from.
      roles = ["roles/cloudkms.cryptoKeyDecrypter"]
    }
  }
}

resource "google_service_account" "components" {
  for_each = local.components

  account_id = "${var.name_prefix}-${each.key}"
  # Service account emails in GCD are NAME@PROJECT.eu0.iam.gserviceaccount.com,
  # and note the project part does NOT carry the eu0: prefix.
  display_name = "${each.key} (agentic platform)"
}

resource "google_project_iam_member" "component_roles" {
  for_each = merge([
    for name, c in local.components : {
      for role in c.roles : "${name}:${role}" => {
        sa   = google_service_account.components[name].email
        role = role
      }
    }
  ]...)

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${each.value.sa}"
}

# Workload Identity binding: only possible once the cluster exists and has
# published its pool, hence the count guard.
resource "google_service_account_iam_member" "workload_identity" {
  # Gated on a plan-time boolean, not on the pool value. See the variable's
  # comment: for_each keys must be known during plan.
  for_each = var.bind_workload_identity ? local.components : {}

  service_account_id = google_service_account.components[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${each.value.ns}/${each.value.ksa}]"
}
