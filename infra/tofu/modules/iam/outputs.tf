output "service_account_emails" {
  value = { for k, v in google_service_account.components : k => v.email }
}

output "ksa_annotations" {
  description = "Paste onto each Kubernetes ServiceAccount: iam.gke.io/gcp-service-account"
  value = {
    for k, v in google_service_account.components :
    "${local.components[k].ns}/${local.components[k].ksa}" => v.email
  }
}
