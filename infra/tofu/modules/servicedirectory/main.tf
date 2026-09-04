# Service Directory as the NETWORK catalogue, alongside agentregistry as the
# GOVERNANCE catalogue. Worth doing in a template because it is a neat, honest
# distinction that a customer immediately gets:
#
#   Service Directory : where is this endpoint, in this VPC
#   agentregistry     : what is this tool, who may call it, which version is
#                       approved, who approved it
#
# They are complementary, and only one of them exists in Google's catalogue.

resource "google_service_directory_namespace" "this" {
  namespace_id = "${var.name_prefix}-agentic"
  location     = var.region
}

locals {
  services = ["agentgateway", "agentregistry", "kagent", "model", "keycloak"]
}

resource "google_service_directory_service" "this" {
  for_each = toset(local.services)

  service_id = each.key
  namespace  = google_service_directory_namespace.this.id

  metadata = {
    tier = each.key == "agentgateway" ? "data-plane" : "control-plane"
  }
}
