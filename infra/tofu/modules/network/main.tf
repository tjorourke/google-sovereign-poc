# A GCD project has no default network, unlike public GCP, so this module is
# mandatory rather than optional. Auto-mode networks would work but contain a
# single subnet (one region), so we build custom-mode for clarity.

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  # Policy-based routes are unavailable in GCD; default routing is all we get.
  routing_mode = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.network_name}-nodes"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # Autopilot is VPC-native only, so pods and services need secondary ranges.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Private Google Access so nodes reach the universe APIs (and Artifact
  # Registry) over the private VIP rather than out through NAT.
  private_ip_google_access = true
}

# ── egress ─────────────────────────────────────────────────────────────────────
# This is the single most important thing in this module. GCD offers Public NAT
# only (Private NAT is unavailable) and IPv4->IPv4 only, with Premium Tier
# addresses. Without this, pods have no route to the internet at all, which
# means no image pulls from ghcr.io and no model weights from Hugging Face.
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── firewall ───────────────────────────────────────────────────────────────────
# Cloud NGFW in GCD is Essentials/Standard only: no security profiles, no
# firewall endpoints, no TLS inspection, no IPS. Plain rules are all there is.

resource "google_compute_firewall" "allow_internal" {
  name      = "${var.network_name}-allow-internal"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "allow_gke_ingress" {
  name        = "${var.network_name}-allow-gke-ingress"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 1000
  description = "GKE control plane and health check ranges, per Berlin's GKE differences page"

  source_ranges = var.gke_ingress_cidrs

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
}
