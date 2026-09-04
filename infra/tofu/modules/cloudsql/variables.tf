variable "project_id" {
  description = "Project id including the eu0: prefix — PSC allowed_consumer_projects wants it."
  type        = string
}

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "tier" { type = string }
variable "labels" { type = map(string) }

variable "kms_key_id" {
  description = "CMEK key. The Cloud SQL service agent must already hold cryptoKeyEncrypterDecrypter on it."
  type        = string
}

variable "network_id" {
  description = "VPC for the Private Service Connect consumer endpoint."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the PSC endpoint address is allocated from."
  type        = string
}

variable "create_psc_endpoint" {
  description = <<-EOT
    Create the Private Service Connect consumer endpoint. Without it the
    instance has NO reachable address at all: GCD has no private services
    access, so PSC is the only private path, and `gcloud sql instances describe`
    returns an empty ipAddresses list until the endpoint exists.
  EOT
  type        = bool
  default     = true
}

variable "databases" {
  description = <<-EOT
    Databases and their owning users to create on the instance. One per product
    that needs Postgres, each with its own user, so a compromise of one product
    does not reach another's data.

    This exists because the Solo charts' bundled Postgres is explicitly labelled
    "for development and evaluation only. Not suitable for production" — and on
    GCD it does not even start: the chart's 500Mi PVC default is below the 4 GB
    minimum for hyperdisk-balanced, which is the only disk type available.
  EOT
  type        = list(string)
  default     = ["agentregistry", "kagent"]
}
