variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "bucket_configs" {
  description = "Data lake bucket configurations per zone"
  type = map(object({
    name_prefix       = string
    location          = string
    storage_class     = string
    retention_days    = number
    versioning        = bool
    lifecycle_rules = list(object({
      age     = number
      storage = string
    }))
  }))
}

variable "kms_key_name" {
  description = "CMEK KMS key name for data lake encryption (empty to auto-create)"
  type        = string
  default     = ""
}

variable "default_labels" {
  description = "Default resource labels"
  type        = map(string)
  default     = {}
}

variable "composer_sa_email" {
  description = "Composer service account email for bucket IAM"
  type        = string
  default     = ""
}

variable "vertex_sa_email" {
  description = "Vertex AI service account email for bucket IAM"
  type        = string
  default     = ""
}
