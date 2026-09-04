output "name" { value = google_container_cluster.this.name }
output "location" { value = google_container_cluster.this.location }
output "endpoint" {
  value     = google_container_cluster.this.endpoint
  sensitive = true
}
output "workload_identity_pool" {
  # GCD uses <project>.eu0.svc.id.goog, NOT <project>.svc.id.goog. Read it from
  # the resource rather than composing it, so a GA rename cannot break us.
  value = try(google_container_cluster.this.workload_identity_config[0].workload_pool, null)
}
