variable "cluster_name" { type = string }
variable "region" { type = string }
variable "network_id" { type = string }
variable "subnet_id" { type = string }
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }
variable "release_channel" { type = string }
variable "labels" { type = map(string) }

variable "enable_private_nodes" {
  description = <<-EOT
    Nodes get no external IP address and reach the internet through Cloud NAT.

    This is the posture a sovereign deployment wants, and it is what makes the
    constraints/compute.vmExternalIpAccess deny-all org policy compatible with a
    working cluster. Without it, Autopilot nodes take a public address and that
    policy silently blocks every node provision.
  EOT
  type        = bool
  default     = true
}

variable "enable_private_endpoint" {
  description = <<-EOT
    Also make the CONTROL PLANE endpoint private. Left false: kubectl runs from
    outside the universe, and with no Cloud VPN or Interconnect configured a
    private-only endpoint would lock us out. Private nodes plus a public control
    plane endpoint is the right split for now.
  EOT
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "Optional allowlist for the control plane endpoint. Empty means any source."
  type        = list(string)
  default     = []
}
