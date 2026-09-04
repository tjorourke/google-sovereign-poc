variable "name_prefix" { type = string }
variable "project_id" { type = string }
variable "workload_identity_pool" {
  description = "From the cluster: <project>.eu0.svc.id.goog. Null before the cluster exists."
  type        = string
  default     = null
}

variable "bind_workload_identity" {
  description = <<-EOT
    Create the Workload Identity bindings. Must be a PLAN-TIME constant, because
    for_each keys cannot depend on an unknown value and the cluster's identity
    pool is unknown until the cluster exists. So: apply once with this false to
    create the cluster, then again with it true. 10-tofu.sh does both passes.
  EOT
  type        = bool
  default     = false
}
variable "kms_key_ids" { type = map(string) }
variable "weights_bucket" { type = string }
