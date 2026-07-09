output "pool_ids" {
  description = "Map of workload name to WIF pool ID"
  value = {
    for k, v in google_iam_workload_identity_pool.wif_pool : k => v.name
  }
}

output "provider_ids" {
  description = "Map of workload name to WIF provider ID"
  value = {
    for k, v in google_iam_workload_identity_pool_provider.wif_provider : k => v.name
  }
}

output "service_accounts" {
  description = "Map of workload name to service account email"
  value = {
    for k, v in var.config : k => (
      v.service_account_email != ""
      ? v.service_account_email
      : google_service_account.wif_sa[k].email
    )
  }
}
