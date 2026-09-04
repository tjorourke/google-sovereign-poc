variable "project_id" { type = string }
variable "region" { type = string }
variable "security_contacts" {
  description = "Emails for Essential Contacts. Note the shared identity caveat in CLAUDE.md."
  type        = list(string)
  default     = []
}

variable "enforce_no_external_ip" {
  description = <<-EOT
    Enforce constraints/compute.vmExternalIpAccess deny-all. LEAVE FALSE unless
    the cluster was created with private nodes: Autopilot nodes DO take an
    external IP, and this policy silently blocks every node provision. The
    cluster then reports RUNNING with zero nodes and every pod Pending, which
    reads as a capacity problem rather than a policy one.
  EOT
  type        = bool
  default     = false
}
