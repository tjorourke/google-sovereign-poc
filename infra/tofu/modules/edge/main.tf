# Tier 1: Google's edge in front of the Solo data plane.
#
# GCD gives us REGIONAL load balancers only — no global, no classic, no
# Cloud CDN, no Media CDN, no Service Extensions, and no backend buckets or
# serverless NEGs. So this is a regional external Application Load Balancer,
# assembled from regional components throughout. Note firewall rules are
# always global even here, and legacy global HTTP health checks are the one
# other documented exception.
#
# What this tier gives us: a static Premium Tier IP, Cloud Armor Standard,
# and TLS termination. What it CANNOT give us, and which is exactly why
# agentgateway sits behind it:
#   - no frontend or backend mTLS
#   - no authorization policies
#   - no Cloud NGFW Enterprise, so no TLS inspection, IPS or URL filtering
#   - no Cloud Armor Enterprise, so no Adaptive Protection, bot management,
#     address groups or Google Threat Intelligence
#   - and no notion whatsoever of an MCP tool, a JSON-RPC method or a token
#     budget
#
# Google protects the HTTP. Solo protects the agent. Draw it that way.

locals {
  serve_tls = var.tls_cert_pem != "" && var.tls_key_pem != ""
  have_negs = length(var.negs) > 0
  neg_keys  = { for n in var.negs : "${n.zone}/${n.name}" => n }
}

resource "google_compute_address" "ingress" {
  name         = "${var.name_prefix}-ingress"
  region       = var.region
  address_type = "EXTERNAL"
  # Standard Tier does not exist in GCD; everything is Premium.
  network_tier = "PREMIUM"
}

# ── Cloud Armor (Standard tier only) ─────────────────────────────────────────
resource "google_compute_region_security_policy" "armor" {
  name        = "${var.name_prefix}-armor"
  region      = var.region
  description = "Cloud Armor Standard. Enterprise is unavailable in GCD."
  type        = "CLOUD_ARMOR"
}

resource "google_compute_region_security_policy_rule" "default_allow" {
  region          = var.region
  security_policy = google_compute_region_security_policy.armor.name
  priority        = 2147483647
  action          = "allow"

  match {
    versioned_expr = "SRC_IPS_V1"
    config {
      src_ip_ranges = ["*"]
    }
  }
}

# ── health check + backend ───────────────────────────────────────────────────
resource "google_compute_region_health_check" "http" {
  name   = "${var.name_prefix}-hc"
  region = var.region

  http_health_check {
    port_specification = "USE_SERVING_PORT"
    request_path       = "/healthz"
  }
}

resource "google_compute_region_backend_service" "agentgateway" {
  count = local.have_negs ? 1 : 0

  name                  = "${var.name_prefix}-agentgateway"
  region                = var.region
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.http.id]
  security_policy       = google_compute_region_security_policy.armor.id

  dynamic "backend" {
    for_each = data.google_compute_network_endpoint_group.gw
    content {
      group                 = backend.value.self_link
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 100
    }
  }
}

# Looked up rather than composed: the project id carries the eu0: prefix and
# hand-built self-links are exactly where that colon causes trouble.
data "google_compute_network_endpoint_group" "gw" {
  for_each = local.neg_keys

  name = each.value.name
  zone = each.value.zone
}

# ── routing ──────────────────────────────────────────────────────────────────
resource "google_compute_region_url_map" "this" {
  count           = local.have_negs ? 1 : 0
  name            = "${var.name_prefix}-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.agentgateway[0].id
}

# ── TLS: BYO only. No Certificate Manager, no managed certs, no ACME. ────────
resource "google_compute_region_ssl_certificate" "byo" {
  count = local.serve_tls ? 1 : 0

  name_prefix = "${var.name_prefix}-cert-"
  region      = var.region
  certificate = var.tls_cert_pem
  private_key = var.tls_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_target_https_proxy" "https" {
  count            = local.have_negs && local.serve_tls ? 1 : 0
  name             = "${var.name_prefix}-https"
  region           = var.region
  url_map          = google_compute_region_url_map.this[0].id
  ssl_certificates = [google_compute_region_ssl_certificate.byo[0].id]
}

resource "google_compute_region_target_http_proxy" "http" {
  count   = local.have_negs && !local.serve_tls ? 1 : 0
  name    = "${var.name_prefix}-http"
  region  = var.region
  url_map = google_compute_region_url_map.this[0].id
}

resource "google_compute_forwarding_rule" "ingress" {
  count = local.have_negs ? 1 : 0

  name                  = "${var.name_prefix}-fr"
  region                = var.region
  ip_address            = google_compute_address.ingress.id
  ip_protocol           = "TCP"
  port_range            = local.serve_tls ? "443" : "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  network               = var.network_id
  target = local.serve_tls ? (
    google_compute_region_target_https_proxy.https[0].id
    ) : (
    google_compute_region_target_http_proxy.http[0].id
  )
}
