output "profile" { value = var.profile }
output "stage" { value = var.stage }
output "region" { value = var.region }
output "project_id" { value = var.project_id }

# ── foundation ────────────────────────────────────────────────────────────────
output "kms_key_ring" { value = module.kms.key_ring_id }
output "kms_keys" { value = module.kms.key_ids }
output "network_name" { value = module.network.network_name }
output "buckets" { value = module.storage.bucket_names }
output "private_dns_zone" { value = try(module.dns[0].dns_name, null) }
output "private_dns_zone_name" {
  description = "Cloud DNS managed-zone NAME (not the dns_name) — what gcloud dns --zone wants."
  value       = try(module.dns[0].zone_name, null)
}

output "envelope_encrypt_hint" {
  description = <<-EOT
    There is no Secret Manager in GCD, and GKE here does not support
    application-layer Secret encryption either, so license keys and LLM
    credentials are envelope-encrypted with this key and the ciphertext is what
    lands in a Kubernetes Secret. Encrypt with:

      gcloud kms encrypt --key <this> --plaintext-file - --ciphertext-file -
  EOT
  value       = module.kms.key_ids["envelope"]
}

# ── platform ──────────────────────────────────────────────────────────────────
output "cluster_name" { value = try(module.cluster_autopilot[0].name, null) }

output "get_credentials_command" {
  description = "Note the quoted eu0: project id — the colon breaks unquoted shell use."
  value = try(
    format(
      "gcloud container clusters get-credentials %s --location %s --project '%s'",
      module.cluster_autopilot[0].name, var.region, var.project_id
    ),
    null
  )
}

output "workload_identity_pool" {
  description = "Expect <project>.eu0.svc.id.goog, not <project>.svc.id.goog."
  value       = try(module.cluster_autopilot[0].workload_identity_pool, null)
}

output "registry_repo" { value = try(module.registry[0].repo_name, null) }

output "registry_uri_command" {
  description = <<-EOT
    The AR host is resolved from the API, never composed — the "<region>-docker"
    prefix is a public-GCP convention and is unconfirmed for Berlin.
  EOT
  value = try(
    format(
      "gcloud artifacts repositories describe %s --location %s --project '%s' --format='value(registryUri)'",
      module.registry[0].repo_name, var.region, var.project_id
    ),
    null
  )
}

output "sql_connection_name" { value = try(module.cloudsql[0].connection_name, null) }

output "sql_psc_endpoint_ip" {
  description = "The address AgentRegistry connects to. GCD has no private services access, so without a PSC endpoint the instance has no reachable IP at all."
  value       = try(module.cloudsql[0].psc_endpoint_ip, null)
}
output "sql_databases" { value = try(module.cloudsql[0].databases, null) }

output "sql_connection_urls" {
  description = "One postgres:// URL per database, against the PSC endpoint, sslmode=require."
  value       = try(module.cloudsql[0].connection_urls, null)
  sensitive   = true
}

output "service_account_emails" { value = try(module.iam[0].service_account_emails, null) }
output "ksa_annotations" {
  description = "Annotate each Kubernetes ServiceAccount with iam.gke.io/gcp-service-account"
  value       = try(module.iam[0].ksa_annotations, null)
}

output "audit_log_bucket" { value = try(module.observability[0].log_bucket, null) }
output "audit_topic" { value = try(module.observability[0].audit_topic, null) }
output "audit_subscription" { value = try(module.observability[0].audit_subscription, null) }
output "audit_bq_dataset" { value = try(module.observability[0].bq_dataset, null) }

output "service_directory_namespace" { value = try(module.servicedirectory[0].namespace, null) }
output "org_policies_applied" { value = try(module.governance[0].org_policies_applied, null) }

# ── edge ──────────────────────────────────────────────────────────────────────
output "ingress_ip" { value = try(module.edge[0].ingress_ip, null) }
output "armor_policy" { value = try(module.edge[0].armor_policy, null) }
output "edge_status" { value = try(module.edge[0].serving, "not at stage=edge yet") }
