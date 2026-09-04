# The audit and analytics path. This module exists because of what GCD's
# managed observability CANNOT do, so read the constraints before changing it.
#
# Cloud Monitoring (/monitoring/docs/tpc-differences) cannot ingest custom
# metrics, Prometheus metrics, OpenTelemetry, client-library metrics or Ops
# Agent metrics, and has no dashboards, alerting policies, uptime checks or
# metrics scopes. Google's own recommendation on that page is "use PromQL and
# Grafana". So agentgateway, kagent and Envoy metrics are self-hosted
# Prometheus + Grafana, installed by 25-cluster-baseline.sh. Nothing here.
#
# Cloud Logging (/logging/docs/tpc-differences) has no Ops Agent, no OSS log
# collection, no log-based metrics, no log alerting, no tailing, and — the
# structural one — sink destinations are project, log bucket and Pub/Sub ONLY.
# NOT BigQuery. NOT Cloud Storage.
#
# Hence the shape below: audit logs land in a CMEK log bucket for retention,
# and a sink fans them to Pub/Sub, from which a subscriber writes BigQuery. It
# is one more hop than public GCP needs, and that hop is the finding.

# ── retention: the evidence store ─────────────────────────────────────────────
resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = var.region
  bucket_id      = "${var.name_prefix}-audit"
  description    = "Audit and platform logs, customer-managed key, long retention"
  retention_days = var.retention_days

  cmek_settings {
    kms_key_name = var.kms_key_id
  }
}

# ── export: the only route out of Logging ─────────────────────────────────────
resource "google_pubsub_topic" "audit" {
  name   = "${var.name_prefix}-audit"
  labels = var.labels

  # Pub/Sub in GCD: no schemas, no Lite, no push-subscription authentication,
  # and no Dataflow/Cloud Run/Functions integrations. A pull subscriber it is.
}

resource "google_logging_project_sink" "audit_to_pubsub" {
  name        = "${var.name_prefix}-audit-to-pubsub"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.audit.id}"

  # Agent, tool and gateway activity plus admin activity. Narrow it later; for
  # a template it is more useful to show the filter than to be minimal.
  filter = <<-EOT
    logName:"cloudaudit.googleapis.com" OR
    resource.type="k8s_container"
  EOT

  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "sink_writer" {
  topic  = google_pubsub_topic.audit.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.audit_to_pubsub.writer_identity
}

resource "google_pubsub_subscription" "audit_to_bq" {
  name  = "${var.name_prefix}-audit-to-bq"
  topic = google_pubsub_topic.audit.id

  # Pull, because push subscriptions cannot be authenticated in GCD. The
  # subscriber that writes BigQuery runs in-cluster.
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"
  labels                     = var.labels
}

# ── analytics ─────────────────────────────────────────────────────────────────
resource "google_bigquery_dataset" "audit" {
  dataset_id  = replace("${var.name_prefix}_audit", "-", "_")
  location    = var.region
  labels      = var.labels
  description = "Agent, tool and gateway audit analytics"

  default_encryption_configuration {
    kms_key_name = var.kms_key_id
  }

  # BigQuery in GCD: BQML internal models only, no column-level access control,
  # no data masking, no scheduled queries, no public datasets, and its own
  # differences page claims Terraform support is unavailable — which this module
  # is a live test of. If it fails, that is a finding, not a bug in this file.
  delete_contents_on_destroy = true
}
