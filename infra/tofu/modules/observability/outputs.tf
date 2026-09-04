output "log_bucket" { value = google_logging_project_bucket_config.audit.id }
output "audit_topic" { value = google_pubsub_topic.audit.name }
output "audit_subscription" { value = google_pubsub_subscription.audit_to_bq.name }
output "bq_dataset" { value = google_bigquery_dataset.audit.dataset_id }
