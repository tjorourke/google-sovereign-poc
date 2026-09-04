output "bucket_names" { value = { for k, v in google_storage_bucket.this : k => v.name } }
output "weights_bucket" { value = google_storage_bucket.this["weights"].name }
output "allowlist_bucket" { value = google_storage_bucket.this["allowlist"].name }
