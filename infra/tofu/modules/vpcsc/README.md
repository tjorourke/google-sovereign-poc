# vpcsc — VPC Service Controls perimeter. OFF BY DEFAULT. READ THIS FIRST.

A service perimeter is the most persuasive control in this template and the
single most dangerous thing in the plan.

**Why it is dangerous here specifically.** GCD's VPC-SC is weakened: no
standalone or custom access levels, no perimeter bridges, and ingress/egress
rules **cannot reference identities, VPC networks, service methods, or
internal-IP access levels** (`/vpc-service-controls/docs/tpc-differences`).
Now combine that with three things this environment already does:

- identity is a **shared bootstrap account**, so there is no per-person escape hatch
- the console **lies about IAM until you re-login**, so a denial looks like a bug
- **Policy Intelligence is absent** — no Policy Troubleshooter, Analyzer or
  Simulator, so there is no tool to ask *why* a call was denied

A bad apply is therefore genuinely hard to diagnose your way out of, and the
support channel that would rescue you does not exist yet (public GCP org +
Assured Workloads folder + 48 business hours).

**The rules.** Build it, leave `enable_vpc_sc = false`, apply it **last**, in
**dry-run mode first** (`google_access_context_manager_service_perimeter` with
`spec` + `use_explicit_dry_run_spec`, not `status`), and only once the support
channel exists. Read the dry-run violations out of Cloud Audit Logs before
promoting anything to enforced.

Not implemented yet, on purpose. Implement it when we are ready to apply it,
not before — a half-written perimeter in the repo is an invitation to apply it
by accident.

Supported services to scope it to, when we do (from Berlin's VPC-SC page):
Access Approval, Artifact Registry, BigQuery, BigQuery Reservation, Cloud DNS,
Cloud KMS, Cloud Logging, Cloud Monitoring, Cloud Storage, Cloud SQL, Compute
Engine, Essential Contacts, GKE, IAM, Organization Policy, Pub/Sub, Resource
Manager, Security Token Service, Service Account Credentials, Service
Directory, Service Usage.
