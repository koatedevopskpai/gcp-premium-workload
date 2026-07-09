output "instance_names" {
  description = "Map of instance role to Workbench instance name"
  value = {
    for k, v in var.instance_configs : k => "${v.name}-${var.environment}"
  }
}

output "instance_ids" {
  description = "Map of instance role to Workbench resource ID"
  value = {
    for k, v in google_workbench_instance.notebook : k => v.id
  }
}

output "service_accounts" {
  description = "Map of instance role to service account email"
  value = {
    for k, v in var.instance_configs : k => (
      v.service_account_email != "" ? v.service_account_email : google_service_account.notebook_sa[k].email
    )
  }
}
