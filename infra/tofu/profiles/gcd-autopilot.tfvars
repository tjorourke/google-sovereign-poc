# Google Cloud Dedicated, Berlin preview.
#
# These are identifiers, not secrets, which is why they are committed — same
# rationale as the table in CLAUDE.md. But berlin-build0 is a pre-GA staging
# name: when it changes at GA, this file is the ONLY place to edit.
profile = "gcd-autopilot"

universe_api_domain      = "apis-berlin-build0.goog"
artifact_registry_domain = "pkg-berlin-build0.goog"
project_id               = "eu0:soloio-eval"
project_short            = "soloio-eval"
project_number           = "560780937444745"
region                   = "u-germany-northeast1"

cluster_name = "agentic"
# 2026-10-21 rebuild for kagent 1.0 on Agent Substrate (poc/2026-10-kagent-substrate).
# Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs: GA and
# served by default on 1.37, beta on 1.36. Berlin offers nothing newer than
# 1.36.4-gke.1391000 (the RAPID default), so this pins that build and enables
# both beta APIs below. RAPID is still not where a customer-facing environment
# should live; it is here because no other channel has 1.36 as its default.
release_channel    = "RAPID"
min_master_version = "1.36.4-gke.1391000"

# Creation-time only: GKE ignores a later change, so editing this means
# recreating the cluster. Empty it once Berlin serves 1.37.
k8s_beta_apis = [
  "certificates.k8s.io/v1beta1/podcertificaterequests",
  "certificates.k8s.io/v1beta1/clustertrustbundles",
]

# Agent Substrate's atelet DaemonSet and gVisor worker pods, admitted through
# WorkloadAllowlists that poc/2026-10-kagent-substrate generates. Each path must
# also be in the org policy (that lab's allowlists/orgpolicy-*.yaml), and must
# be set here at creation to avoid a ~20 minute cluster update. The spares are
# authorised but empty until needed. Istio's paths are gone: no mesh this time.
autopilot_privileged_admission = [
  "gke://*",
  "gs://agentic-allowlist/substrate/0.6.0-alpha3/atelet.yaml",
  "gs://agentic-allowlist/substrate/0.6.0-alpha3/ateworker-gvisor.yaml",
  "gs://agentic-allowlist/substrate/spare-1.yaml",
  "gs://agentic-allowlist/substrate/spare-2.yaml",
]
# The cluster exists and these five bindings are live. A default plan must not
# propose deleting them just because the bootstrap second-pass flag was omitted.
bind_workload_identity = true

network_name  = "agentic"
subnet_cidr   = "10.20.0.0/20"
pods_cidr     = "10.32.0.0/14"
services_cidr = "10.36.0.0/20"

registry_repo = "solo"

# Cloud SQL rather than AgentRegistry's bundled Postgres: Autopilot admission
# plus Hyperdisk-Balanced-only storage make the bundled StatefulSet the riskier
# option, and Cloud SQL is what a regulated customer would actually ship.
enable_cloudsql = true
cloudsql_tier   = "db-perf-optimized-C-4"

# ON. A private zone is what removes the kind lab's hostAlias bridge and makes
# the OIDC issuer hostname resolve natively in-cluster. Public zones do not
# exist in GCD, so private is the only kind available.
enable_private_dns = true
private_dns_domain = "agentic.eu0.internal."

# Essential Contacts. Note our signed-in identity is the SHARED preview-soloio
# account, so these are the only per-person notification path in the whole
# environment until Solo's own IdP is federated (probe 0.17).
security_contacts = ["tom.orourke@solo.io"]

# VPC-SC perimeter. LEAVE FALSE. Read modules/vpcsc/README.md first: GCD's
# VPC-SC cannot reference identities or VPC networks in its rules, identity here
# is a shared bootstrap account, the console lies about IAM until you re-login,
# and there is no Policy Troubleshooter. A bad apply is hard to escape and the
# support channel that would rescue you does not exist yet.
enable_vpc_sc = false

# Safe now: the cluster runs private nodes, so no node asks for an external IP
# and this constraint no longer blocks provisioning. Egress goes via Cloud NAT.
enforce_no_external_ip = true
