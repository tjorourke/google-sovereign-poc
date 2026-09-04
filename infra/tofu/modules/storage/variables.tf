variable "name_prefix" { type = string }
variable "region" { type = string }
variable "kms_key_id" { type = string }
variable "labels" { type = map(string) }

# GKE service agent email, e.g.
# service-NUMBER@container-engine-robot.eu0-system.iam.gserviceaccount.com
# Empty disables the allowlist bucket grant.
variable "gke_service_agent" {
  type    = string
  default = ""
}
