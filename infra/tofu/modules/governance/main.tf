# The governance layer. Cheap to build, disproportionately persuasive to a
# regulated buyer, and it exercises three services we would otherwise ignore.
#
# GCD constraint that shapes this whole module: Organization Policy here
# supports PREDEFINED constraints only. You cannot create custom constraints
# and you cannot use managed constraints (/iam/docs/tpc-differences). So this
# is a curated list of the built-ins that actually mean something here, not the
# usual bespoke-constraint landing zone.

# ── resource location ────────────────────────────────────────────────────────
# NOT AVAILABLE. `gcp.resourceLocations` returns 404 "Requested entity was not
# found" on apply, so the constraint does not exist in GCD's predefined set.
#
# Ironically this is the org policy a sovereign customer would most want, and
# it is also the one GCD needs least: the universe has a single region, so
# there is nowhere else for a resource to go. Worth confirming with Google that
# its absence is intentional rather than an omission, because a customer's
# compliance team will ask for the constraint by name.
#
# resource "google_project_organization_policy" "resource_locations" {
#   project    = var.project_id
#   constraint = "gcp.resourceLocations"
#   list_policy { allow { values = ["in:${var.region}"] } }
# }

# ── no external IPs on VMs ───────────────────────────────────────────────────
# OFF BY DEFAULT, and this is the most expensive thing we got wrong today.
#
# The assumption was that Autopilot nodes take no external IP, so a deny-all
# would be free. They DO take one (our first node came up on 34.3.143.41), so
# the policy silently broke every subsequent node provision:
#
#   ScaleUpFailed: Failed adding 1 nodes to group ... due to
#   Other.VM_EXTERNAL_IP_ACCESS_POLICY_CONSTRAINT; source errors: Instance
#   'gk3-agentic-nap-...' creation failed: Constraint
#   constraints/compute.vmExternalIpAccess violated for project 560780937444745
#
# The cluster reported RUNNING with zero nodes and every pod stuck Pending, so
# the symptom looked like a quota or capacity problem rather than a policy one.
#
# The correct way to have both this policy and a working cluster is to create
# the cluster with PRIVATE NODES, which is why the network module provisions
# Cloud NAT. That is a cluster-recreate, so it is a deliberate follow-up rather
# than something to flip on blind. Until then, leave this false.
resource "google_project_organization_policy" "no_external_ip" {
  count      = var.enforce_no_external_ip ? 1 : 0
  project    = var.project_id
  constraint = "compute.vmExternalIpAccess"

  list_policy {
    deny {
      all = true
    }
  }
}

resource "google_project_organization_policy" "shielded_vm" {
  project    = var.project_id
  constraint = "compute.requireShieldedVm"

  boolean_policy {
    enforced = true
  }
}

# Uniform bucket-level access: turns off ACLs, so IAM is the only access path.
resource "google_project_organization_policy" "uniform_bucket_access" {
  project    = var.project_id
  constraint = "storage.uniformBucketLevelAccess"

  boolean_policy {
    enforced = true
  }
}

# ── Essential Contacts ───────────────────────────────────────────────────────
# Worth noting for the write-up: our signed-in identity is the SHARED
# preview-soloio account, so contacts here are the only per-person notification
# path in the whole environment until Solo's own IdP is federated.
resource "google_essential_contacts_contact" "security" {
  for_each = toset(var.security_contacts)

  parent                              = "projects/${var.project_id}"
  email                               = each.key
  language_tag                        = "en"
  notification_category_subscriptions = ["SECURITY", "TECHNICAL"]
}
