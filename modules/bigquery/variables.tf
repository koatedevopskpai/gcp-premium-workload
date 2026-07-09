variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "dataset_config" {
  description = "BigQuery dataset configuration"
  type = object({
    dataset_id       = string
    description      = string
    location         = string
    default_ttl_days = number
    kms_key_name     = string
    column_acls = map(object({
      sensitive_columns = list(string)
      authorized_group  = string
    }))
    row_access_policies = map(object({
      filter_column   = string
      masked_value    = string
      authorized_user = string
    }))
  })
}

variable "kms_key_name" {
  description = "CMEK KMS key name for BigQuery encryption (empty string to create)"
  type        = string
  default     = ""
}

variable "default_labels" {
  description = "Default resource labels"
  type        = map(string)
  default     = {}
}

variable "dataset_owners" {
  description = "Dataset owner email addresses"
  type        = list(string)
  default     = []
}
