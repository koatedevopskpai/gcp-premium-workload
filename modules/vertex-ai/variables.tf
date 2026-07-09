variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west2"
}

variable "instance_configs" {
  description = "Vertex AI Workbench instance configurations"
  type = map(object({
    name                  = string
    machine_type          = string
    accelerator_type      = string
    accelerator_count     = number
    boot_disk_size_gb     = number
    boot_disk_type        = string
    data_disk_size_gb     = number
    data_disk_type        = string
    network               = string
    subnet                = string
    kms_key_name          = string
    service_account_email = string
    idle_shutdown_minutes = number
  }))
}

variable "kms_key_name" {
  description = "Default CMEK key name for instances (overridden per-instance if set)"
  type        = string
  default     = ""
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
