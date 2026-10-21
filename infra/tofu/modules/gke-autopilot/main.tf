# GKE Autopilot. On GCD this is the ONLY mode — Standard clusters do not exist.
#
# What that costs us, from /kubernetes-engine/docs/tpc-differences:
#   - privileged workloads need approved WorkloadAllowlists. Phases 62/63
#     installed them for Solo Istio ambient (2026-09); since the 2026-10-21
#     rebuild, poc/2026-10-kagent-substrate/scripts/20-allowlists.sh installs
#     Agent Substrate's (atelet DaemonSet, gVisor worker pods).
#   - Cloud Service Mesh is unavailable, so there is no managed alternative
#   - GKE network policies are unavailable
#   - max 32 pods per node; Hyperdisk Balanced storage only
#   - general-purpose and Accelerator compute classes only
#   - service agents are provisioned just-in-time on first resource creation,
#     not on API enable
#
# Nothing below can change any of that. It is recorded here so the next person
# does not go looking for a node_config block to fix it in.

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region

  enable_autopilot               = true
  autopilot_privileged_admission = var.autopilot_privileged_admission
  deletion_protection            = false # POC; flip for anything long-lived

  network    = var.network_id
  subnetwork = var.subnet_id

  # VPC-native is the only option here. Route-based clusters do not exist.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Empty string means "channel default"; the provider omits the field.
  min_master_version = var.min_master_version != "" ? var.min_master_version : null

  release_channel {
    channel = var.release_channel
  }

  # Beta Kubernetes APIs, e.g. the PodCertificateRequest and ClusterTrustBundle
  # APIs Agent Substrate needs on 1.36. GKE honours this only at CREATION: added
  # later, the update succeeds and the APIs are still not served, so the cluster
  # has to be recreated. Empty (the 1.37+ case, where both are GA) omits it.
  dynamic "enable_k8s_beta_apis" {
    for_each = length(var.k8s_beta_apis) > 0 ? [1] : []
    content {
      enabled_apis = var.k8s_beta_apis
    }
  }

  # ── node network isolation ─────────────────────────────────────────────────
  # Private nodes have no external IP and egress via Cloud NAT, which the
  # network module provisions. This is the whole reason NAT is there, and it is
  # what lets the deny-all external-IP org policy coexist with a live cluster.
  private_cluster_config {
    enable_private_nodes    = var.enable_private_nodes
    enable_private_endpoint = var.enable_private_endpoint
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block = cidr_blocks.value
        }
      }
    }
  }

  resource_labels = var.labels

  # Autopilot manages logging/monitoring itself. Worth knowing that on GCD the
  # destination is nearly useless to us: Cloud Monitoring cannot ingest custom,
  # Prometheus or OpenTelemetry metrics, and Cloud Logging cannot do log-based
  # metrics or sink to BigQuery/GCS. Telemetry for the Solo stack therefore comes
  # from the in-cluster OTel collector + ClickHouse in the management chart.

  lifecycle {
    # Autopilot mutates a long list of fields server-side on create. Without
    # this, every subsequent plan shows spurious diffs.
    ignore_changes = [
      node_config,
      node_pool,
    ]
  }
}
