output "org_policies_applied" {
  value = concat(
    [
      google_project_organization_policy.shielded_vm.constraint,
      google_project_organization_policy.uniform_bucket_access.constraint,
    ],
    [for p in google_project_organization_policy.no_external_ip : p.constraint],
  )
}
