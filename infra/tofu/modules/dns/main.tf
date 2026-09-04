# A PRIVATE Cloud DNS zone. GCD has no public zones and no public reverse
# lookup, so this is the only kind of zone available — and the reason ACME
# DNS-01 is not a path to certificates here.
#
# Off by default (var.enable_private_dns). The first pass of the lab uses
# *.localtest.me plus a hostAlias bridge, which needs no DNS at all. Turn this
# on for the customer-shaped variant, where pods resolve the console hostnames
# natively and the hostAlias disappears.
resource "google_dns_managed_zone" "private" {
  name        = var.zone_name
  dns_name    = var.dns_name
  description = "Private zone for the agentic platform console hostnames"
  visibility  = "private"
  labels      = var.labels

  private_visibility_config {
    networks {
      network_url = var.network_id
    }
  }
}
