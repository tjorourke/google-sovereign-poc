variable "name_prefix" { type = string }
variable "region" { type = string }
variable "network_id" { type = string }
variable "subnet_id" { type = string }
variable "labels" { type = map(string) }

variable "negs" {
  description = <<-EOT
    Zonal NEGs published by the agentgateway Gateway Service, as
    [{ zone = "u-germany-northeast1-a", name = "k8s1-..." }, ...].

    Empty until agentgateway is installed and its Service annotated, which is
    why the edge module applies LAST (stage 1d). Read them with:

      kubectl -n agentgateway-system get svc <gw-svc> -o \
        jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}'

    Looked up through a data source rather than composing self-links by hand,
    because the project id carries the eu0: prefix and hand-built URLs are
    exactly where that colon causes trouble.
  EOT
  type = list(object({
    zone = string
    name = string
  }))
  default = []
}

variable "tls_cert_pem" {
  description = "BYO leaf certificate. No Certificate Manager and no ACME in GCD, so this is hand-managed. Empty = HTTP only."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_key_pem" {
  type      = string
  default   = ""
  sensitive = true
}
