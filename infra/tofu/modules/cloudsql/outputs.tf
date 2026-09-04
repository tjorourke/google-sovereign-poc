output "instance_name" { value = google_sql_database_instance.pg.name }
output "connection_name" { value = google_sql_database_instance.pg.connection_name }
output "databases" { value = [for d in google_sql_database.db : d.name] }

output "credentials" {
  description = "Per-database user and password."
  value       = { for k, v in random_password.app : k => { user = k, password = v.result } }
  sensitive   = true
}

output "connection_urls" {
  description = <<-EOT
    Ready-to-use postgres:// URLs against the PSC endpoint, one per database.
    sslmode=require, because Cloud SQL Enterprise Plus accepts TLS and there is
    no reason for a sovereign deployment to send credentials in the clear even
    inside the VPC.
  EOT
  value = var.create_psc_endpoint ? {
    for k, v in random_password.app : k =>
    "postgres://${k}:${v.result}@${google_compute_address.psc[0].address}:5432/${k}?sslmode=require"
  } : {}
  sensitive = true
}

output "psc_endpoint_ip" {
  description = "The address AgentRegistry connects to. Null if no endpoint was created."
  value       = try(google_compute_address.psc[0].address, null)
}

output "psc_service_attachment" {
  value = google_sql_database_instance.pg.psc_service_attachment_link
}
