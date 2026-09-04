# Cloud KMS is the spine of the sovereignty story in this template, and also
# where we have to be most careful about what we claim.
#
# What GCD's KMS does NOT have (/kms/docs/tpc-differences):
#   - NO HSM protection level, neither multi-tenant Cloud HSM nor
#     single-tenant. SOFTWARE is the ceiling.
#   - NO EKM (the EXTERNAL protection level is unsupported)
#   - NO Cloud KMS Autokey (it requires Cloud HSM)
#   - no key tracking, no Inventory API, no generateRandomBytes
#   - locations: u-germany-northeast1 and global only
#
# So: do not tell a regulated buyer these are HSM-backed keys. They are
# software-protected customer-managed keys in a partner-operated universe,
# which is still a real story — just a different sentence.

resource "google_kms_key_ring" "this" {
  name     = "${var.name_prefix}-kr"
  location = var.region
}

locals {
  # One key per consuming service, so a compromise or a rotation is scoped.
  # "envelope" is the odd one out: it exists because there is no Secret Manager
  # in GCD, so Solo license keys and LLM credentials are encrypted with it and
  # the ciphertext is what lands in a Kubernetes Secret.
  keys = ["sql", "storage", "registry", "logging", "envelope"]
}

resource "google_kms_crypto_key" "keys" {
  for_each = toset(local.keys)

  name     = each.key
  key_ring = google_kms_key_ring.this.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = var.rotation_period

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
    # SOFTWARE is not a choice here, it is the only protection level GCD
    # offers. Stated explicitly so nobody "upgrades" this to HSM and wonders
    # why the apply fails.
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true
  }
}
