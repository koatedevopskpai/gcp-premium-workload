variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "config" {
  description = "Workload Identity Federation pool and provider configurations"
  type = map(object({
    pool_id               = string
    provider_id           = string
    issuer_uri            = string
    allowed_audiences     = list(string)
    attribute_mapping     = map(string)
    service_account_email = string
    attribute_condition   = string
  }))
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
