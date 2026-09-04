output "network_id" { value = google_compute_network.vpc.id }
output "network_name" { value = google_compute_network.vpc.name }
output "subnet_id" { value = google_compute_subnetwork.nodes.id }
output "subnet_name" { value = google_compute_subnetwork.nodes.name }
output "pods_range_name" { value = "pods" }
output "services_range_name" { value = "services" }
