# Root module. One config, two profiles, three stages.
#
#   profile: gcd-autopilot | gcp-standard
#   stage:   foundation -> platform -> edge
#
#   tofu apply -var-file=profiles/gcd-autopilot.tfvars -var stage=foundation
#   ./10-tofu.sh apply   # drives the stages in order
#
# Staged on purpose. GCD provisions service agents JUST-IN-TIME on first
# resource creation rather than on API enable, so every CMEK binding needs its
# consuming service's agent to exist and hold cryptoKeyEncrypterDecrypter on
# the key BEFORE the resource is created. 10-tofu.sh creates those agents
# between `foundation` and `platform`. If a CMEK resource 400s about the key,
# that is the missing agent, not a bad key.

locals {
  is_gcd = var.profile == "gcd-autopilot"

  do_foundation = true
  do_platform   = contains(["platform", "edge"], var.stage)
  do_edge       = var.stage == "edge"

  name_prefix = var.cluster_name

  # GCD has exactly three zones. Derived rather than hardcoded so the gcp-standard
  # profile is not wrong.
  zones = [for z in ["a", "b", "c"] : "${var.region}-${z}"]
}

# ══ stage: foundation ═════════════════════════════════════════════════════════

module "kms" {
  source = "./modules/kms"

  name_prefix = local.name_prefix
  region      = var.region
}

module "network" {
  source = "./modules/network"

  network_name      = var.network_name
  region            = var.region
  subnet_cidr       = var.subnet_cidr
  pods_cidr         = var.pods_cidr
  services_cidr     = var.services_cidr
  gke_ingress_cidrs = var.gke_ingress_cidrs
}

module "storage" {
  source = "./modules/storage"

  name_prefix = local.name_prefix
  region      = var.region
  kms_key_id  = module.kms.key_ids["storage"]
  labels      = var.labels

  # Service agents in GCD keep the universe-system domain. 10-tofu.sh provisions
  # this agent just-in-time before this module applies.
  gke_service_agent = "service-${var.project_number}@container-engine-robot.eu0-system.iam.gserviceaccount.com"
}

module "dns" {
  source = "./modules/dns"
  count  = var.enable_private_dns ? 1 : 0

  zone_name  = "${local.name_prefix}-private"
  dns_name   = var.private_dns_domain
  network_id = module.network.network_id
  labels     = var.labels
}

# ══ stage: platform ═══════════════════════════════════════════════════════════

module "registry" {
  source = "./modules/registry"
  count  = local.do_platform ? 1 : 0

  repo_name  = var.registry_repo
  region     = var.region
  kms_key_id = module.kms.key_ids["registry"]
  labels     = var.labels
}

module "cluster_autopilot" {
  source = "./modules/gke-autopilot"
  count  = local.do_platform && local.is_gcd ? 1 : 0

  cluster_name        = var.cluster_name
  region              = var.region
  network_id          = module.network.network_id
  subnet_id           = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  release_channel     = var.release_channel
  labels              = var.labels

  enable_private_nodes = var.enable_private_nodes
}

module "cloudsql" {
  source = "./modules/cloudsql"
  count  = local.do_platform && var.enable_cloudsql ? 1 : 0

  name_prefix = local.name_prefix
  project_id  = var.project_id
  region      = var.region
  tier        = var.cloudsql_tier
  kms_key_id  = module.kms.key_ids["sql"]
  network_id  = module.network.network_id
  subnet_id   = module.network.subnet_id
  labels      = var.labels
}

module "iam" {
  source = "./modules/iam"
  count  = local.do_platform ? 1 : 0

  name_prefix            = local.name_prefix
  project_id             = var.project_id
  workload_identity_pool = try(module.cluster_autopilot[0].workload_identity_pool, null)
  bind_workload_identity = var.bind_workload_identity
  kms_key_ids            = module.kms.key_ids
  weights_bucket         = module.storage.weights_bucket
}

module "observability" {
  source = "./modules/observability"
  count  = local.do_platform ? 1 : 0

  name_prefix = local.name_prefix
  project_id  = var.project_id
  region      = var.region
  kms_key_id  = module.kms.key_ids["logging"]
  labels      = var.labels
}

module "servicedirectory" {
  source = "./modules/servicedirectory"
  count  = local.do_platform ? 1 : 0

  name_prefix = local.name_prefix
  region      = var.region
}

module "governance" {
  source = "./modules/governance"
  count  = local.do_platform ? 1 : 0

  project_id             = var.project_id
  region                 = var.region
  security_contacts      = var.security_contacts
  enforce_no_external_ip = var.enforce_no_external_ip
}

# ══ stage: edge ═══════════════════════════════════════════════════════════════
# Applies last: the backend service needs the zonal NEGs that only exist once
# agentgateway is installed and its Gateway Service is annotated.

module "edge" {
  source = "./modules/edge"
  count  = local.do_edge ? 1 : 0

  name_prefix  = local.name_prefix
  region       = var.region
  network_id   = module.network.network_id
  subnet_id    = module.network.subnet_id
  negs         = var.gateway_negs
  tls_cert_pem = var.tls_cert_pem
  tls_key_pem  = var.tls_key_pem
  labels       = var.labels
}

# ══ NOT WIRED: vpcsc ══════════════════════════════════════════════════════════
# Deliberately not referenced. See modules/vpcsc/README.md — a half-written
# perimeter in the repo is an invitation to apply it by accident. var.enable_vpc_sc
# exists so the intent is visible; the module is implemented when we are ready
# to apply it, dry-run first, after the support channel exists.
