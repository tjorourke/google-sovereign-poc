# Postgres for AgentRegistry, instead of its bundled StatefulSet.
#
# GCD constraints, from /sql/docs/tpc-differences:
#   - Enterprise Plus edition ONLY (Enterprise is unavailable)
#   - C3 machine types only: db-perf-optimized-C-4 .. -176
#   - Hyperdisk Balanced / Balanced HA storage only; no data cache
#   - IAM database authentication is SERVICE-ACCOUNT ONLY. No user or group
#     IAM auth, which matters for how AgentRegistry connects.
#   - Private Service Connect is available; PRIVATE SERVICES ACCESS IS NOT.
#     That rules out the usual ip_configuration.private_network approach, so
#     connectivity is PSC or public IP.
#   - no Database Migration Service, no query insights
#   - MAINTENANCE TRAP: an instance configured with a maintenance window
#     receives NO automatic updates in GCD. Leaving the window unset is the
#     safer default, so this module does not set one.

resource "random_id" "suffix" {
  byte_length = 3
}

resource "google_sql_database_instance" "pg" {
  name             = "${var.name_prefix}-pg-${random_id.suffix.hex}"
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = false # POC
  encryption_key_name = var.kms_key_id

  settings {
    tier    = var.tier
    edition = "ENTERPRISE_PLUS"

    # Hyperdisk Balanced is the only disk type available in the universe.
    disk_type       = "HYPERDISK_BALANCED"
    disk_size       = 20
    disk_autoresize = true

    user_labels = var.labels

    ip_configuration {
      # PSC, because private services access does not exist here. The consumer
      # endpoint is created separately once we know the cluster's subnet; see
      # PLAN.md phase 1. ipv4_enabled stays false so nothing is public.
      ipv4_enabled = false

      psc_config {
        psc_enabled = true
        # The consumer project must be listed or the endpoint below is refused.
        # Note the eu0: prefix is required here, unlike in an image reference.
        allowed_consumer_projects = [var.project_id]
      }
    }

    backup_configuration {
      enabled = true
      # No cross-region anything in GCD: one region, three zones. Backups are
      # in-region by definition, which is the point.
    }

    # Deliberately no maintenance_window block — see the trap noted above.
  }
}

# One database and one owning user per product. Keeping them separate means a
# compromise of one product's credentials does not reach another's data, which
# is the whole reason not to share a single bundled instance.
resource "google_sql_database" "db" {
  for_each = toset(var.databases)

  name     = each.key
  instance = google_sql_database_instance.pg.name
}

resource "random_password" "app" {
  for_each = toset(var.databases)

  length  = 32
  special = false # keeps the value safe to embed in a postgres:// URL unescaped
}

resource "google_sql_user" "app" {
  for_each = toset(var.databases)

  name     = each.key
  instance = google_sql_database_instance.pg.name
  password = random_password.app[each.key].result
}


# ── Private Service Connect consumer endpoint ────────────────────────────────
# This is easy to miss and it is load-bearing. GCD has NO private services
# access (`/sql/docs/tpc-differences`), so PSC is the only private route to the
# instance, and the instance is created with an empty `ipAddresses` list — it is
# simply unreachable until a consumer endpoint exists in the VPC. Nothing errors;
# a client just cannot connect.
#
# The service attachment Cloud SQL publishes lives in a Google-managed tenant
# project whose id itself carries a universe prefix
# (projects/eu0-system:...-tp/regions/.../serviceAttachments/...), which is worth
# knowing if you ever hand-build this URI.

resource "google_compute_address" "psc" {
  count = var.create_psc_endpoint ? 1 : 0

  name         = "${var.name_prefix}-sql-psc"
  region       = var.region
  subnetwork   = var.subnet_id
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_forwarding_rule" "psc" {
  count = var.create_psc_endpoint ? 1 : 0

  name                  = "${var.name_prefix}-sql-psc"
  region                = var.region
  network               = var.network_id
  ip_address            = google_compute_address.psc[0].self_link
  target                = google_sql_database_instance.pg.psc_service_attachment_link
  load_balancing_scheme = "" # required to be empty for a PSC endpoint
}
