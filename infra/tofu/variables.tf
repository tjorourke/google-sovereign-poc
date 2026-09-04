variable "profile" {
  description = <<-EOT
    Which universe shape to build.
      gcd-autopilot : Google Cloud Dedicated, Berlin. Autopilot only, no mesh.
      gcp-standard  : public GCP, GKE Standard. Track A, supports Istio ambient.
    Every profile-specific value comes from profiles/<profile>.tfvars.
  EOT
  type        = string
  validation {
    condition     = contains(["gcd-autopilot", "gcp-standard"], var.profile)
    error_message = "profile must be gcd-autopilot or gcp-standard."
  }
}

# ── universe ───────────────────────────────────────────────────────────────────
# Nothing in infra/ hardcodes a hostname: berlin-build0 and devsitetest.how are
# pre-GA staging names and will change at GA.
variable "universe_api_domain" {
  description = "Universe API domain, e.g. apis-berlin-build0.goog. Empty string means public GCP."
  type        = string
}

variable "artifact_registry_domain" {
  description = "Artifact Registry domain for the universe, e.g. pkg-berlin-build0.goog (replaces pkg.dev)."
  type        = string
}

variable "project_id" {
  description = "Project id INCLUDING the universe prefix, e.g. eu0:soloio-eval. Quote it everywhere."
  type        = string
}

variable "project_short" {
  description = <<-EOT
    Project id WITHOUT the universe prefix, e.g. soloio-eval. Needed because a
    colon is not legal inside a docker reference path component, so anything that
    builds an image ref may have to use this instead of project_id. See PLAN.md
    probe 0.8 — which of the two Artifact Registry actually wants is unconfirmed.
  EOT
  type        = string
}

variable "region" {
  description = "Region, e.g. u-germany-northeast1. GCD has exactly one."
  type        = string
}

# ── network ────────────────────────────────────────────────────────────────────
variable "network_name" {
  description = "VPC name. GCD creates no default network, so this is mandatory."
  type        = string
  default     = "agentic"
}

variable "subnet_cidr" {
  description = "Primary subnet range for nodes."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pods. Autopilot is VPC-native only."
  type        = string
  default     = "10.32.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range for services."
  type        = string
  default     = "10.36.0.0/20"
}

variable "gke_ingress_cidrs" {
  description = <<-EOT
    Ranges GKE health checks and the control plane come from, per Berlin's GKE
    differences page. Needed on ingress firewall rules.
  EOT
  type        = list(string)
  default     = ["34.3.144.0/23", "34.3.151.0/26"]
}

# ── cluster ────────────────────────────────────────────────────────────────────
variable "cluster_name" {
  type    = string
  default = "agentic"
}

variable "release_channel" {
  description = "GCD offers STABLE and REGULAR only. RAPID does not exist here."
  type        = string
  default     = "REGULAR"
  validation {
    condition     = contains(["STABLE", "REGULAR"], var.release_channel)
    error_message = "GCD offers STABLE and REGULAR only."
  }
}

# ── registry ───────────────────────────────────────────────────────────────────
variable "registry_repo" {
  description = "Artifact Registry repo name. Docker format, standard mode — GCD has no remote or virtual repos, so no pull-through mirror."
  type        = string
  default     = "solo"
}

# ── database ───────────────────────────────────────────────────────────────────
variable "enable_cloudsql" {
  description = <<-EOT
    Provision Cloud SQL Postgres for AgentRegistry instead of its bundled
    Postgres. True on GCD: Autopilot admission plus Hyperdisk-Balanced-only
    storage make a bundled StatefulSet the riskier option, and Cloud SQL is the
    answer a regulated customer would actually ship.
  EOT
  type        = bool
  default     = true
}

variable "cloudsql_tier" {
  description = "GCD offers Enterprise Plus on C3 only: db-perf-optimized-C-4 .. -176."
  type        = string
  default     = "db-perf-optimized-C-4"
}

# ── dns ────────────────────────────────────────────────────────────────────────
variable "enable_private_dns" {
  description = <<-EOT
    Create a Cloud DNS PRIVATE zone. Public zones do not exist in GCD. Off for
    the first pass: the lab uses *.localtest.me plus a hostAlias bridge, which
    needs no DNS at all. Turn this on for the customer-shaped variant.
  EOT
  type        = bool
  default     = false
}

variable "private_dns_domain" {
  description = "Private zone DNS name, trailing dot. e.g. agentic.eu0.internal."
  type        = string
  default     = "agentic.eu0.internal."
}

variable "labels" {
  type = map(string)
  default = {
    managed-by = "opentofu"
    purpose    = "agentic-platform-eval"
  }
}

# ── staging ────────────────────────────────────────────────────────────────────
# Phase 1 applies in four stages, because a single apply that touches KMS, a
# cluster and a service perimeter is undebuggable on an unproven cloud — and
# because the JIT service-agent problem forces an ordering. See PLAN.md.
variable "stage" {
  description = <<-EOT
    foundation : KMS, network, NAT, DNS, buckets
    platform   : + registry, Cloud SQL, cluster, IAM, observability,
                 Service Directory, governance
    edge       : + static IP, regional external ALB, Cloud Armor, TLS cert
                 (needs the NEGs agentgateway publishes, so it is last)
  EOT
  type        = string
  default     = "platform"
  validation {
    condition     = contains(["foundation", "platform", "edge"], var.stage)
    error_message = "stage must be foundation, platform or edge."
  }
}

variable "gateway_negs" {
  description = "Zonal NEGs from the agentgateway Gateway Service. Only used at stage=edge."
  type = list(object({
    zone = string
    name = string
  }))
  default = []
}

variable "tls_cert_pem" {
  description = "BYO leaf cert for the external ALB. No Certificate Manager or ACME in GCD. Empty = HTTP."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_key_pem" {
  type      = string
  default   = ""
  sensitive = true
}

variable "security_contacts" {
  description = "Essential Contacts emails."
  type        = list(string)
  default     = []
}

variable "enable_vpc_sc" {
  description = "VPC-SC perimeter. Leave FALSE. See modules/vpcsc/README.md before changing."
  type        = bool
  default     = false
}

variable "bind_workload_identity" {
  description = <<-EOT
    Second-pass flag. The Workload Identity bindings need the cluster's identity
    pool, which does not exist until the cluster does, and for_each keys must be
    known at plan time. So stage=platform runs twice: once with this false to
    build the cluster, once with it true to bind. 10-tofu.sh handles both.
  EOT
  type        = bool
  default     = false
}

variable "enable_private_nodes" {
  description = "Autopilot nodes take no external IP and egress via Cloud NAT. See the module."
  type        = bool
  default     = true
}

variable "enforce_no_external_ip" {
  description = "Only safe with private nodes. See modules/governance."
  type        = bool
  default     = false
}

# Project NUMBER, not id. Needed to build service agent emails, which carry the
# number rather than the project id. Near-identical to the org number in this
# universe, so double-check it.
variable "project_number" {
  type        = string
  description = "Project number, e.g. 560780937444745. Used for service agent emails."
}
