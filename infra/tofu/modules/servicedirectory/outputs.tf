output "namespace" { value = google_service_directory_namespace.this.name }
output "services" { value = { for k, v in google_service_directory_service.this : k => v.name } }
