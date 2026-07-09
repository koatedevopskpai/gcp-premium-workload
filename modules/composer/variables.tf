variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "composer_config" {
  description = "Cloud Composer configuration"
  type = object({
    region               = optional(string, "europe-west2")
    environment_size     = string
    scheduler_count      = number
    worker_count         = number
    web_server_count     = number
    airflow_version      = string
    airflow_config_overrides = map(string)
    env_variables        = map(string)
    network              = string
    subnetwork           = string
    network_cidr         = optional(string, "10.0.0.0/8")
    kms_key_name         = string
    service_account_email = string
  })
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}

variable "terraform_operator_cidr" {
  description = "CIDR block for Terraform operator access to Composer API"
  type        = string
  default     = "0.0.0.0/0"
}
