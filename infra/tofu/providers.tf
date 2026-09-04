# Provider wiring for a Google Cloud Dedicated universe.
#
# Two things here are load-bearing and both fail silently if you get them wrong:
#
#   1. universe_domain. Without it the provider talks to googleapis.com — the
#      public cloud — and you get 403/404 on resources that do not exist.
#   2. The provider version. universe_domain was originally plumbed only into
#      the SDK code path, not the plugin-framework path, so an older provider
#      silently uses googleapis.com for PF-migrated resources. Fixed upstream,
#      but pin high and verify: after the first apply, check the audit log in
#      the universe shows the calls, not just a happy plan.
terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source = "hashicorp/google"
      # 8.1.0 is what this config was validated against (2026-09-03). Pin high:
      # older providers silently use googleapis.com for plugin-framework
      # resources even with universe_domain set.
      version = ">= 8.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

provider "google" {
  universe_domain = var.universe_api_domain
  project         = var.project_id
  region          = var.region
}
