output "ingress_ip" { value = google_compute_address.ingress.address }
output "armor_policy" { value = google_compute_region_security_policy.armor.name }
output "serving" {
  value = length(google_compute_forwarding_rule.ingress) > 0 ? "wired" : "waiting for NEGs from agentgateway (stage 1d)"
}
