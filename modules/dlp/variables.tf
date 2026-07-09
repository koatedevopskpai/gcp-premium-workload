variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
}

variable "config" {
  description = "Cloud DLP configuration"
  type = object({
    inspection_template_id      = string
    deidentify_template_id      = string
    job_trigger_id              = string
    scan_frequency_minutes      = number
    inspect_max_findings        = number
    inspection_targets          = list(string)
  })
}

variable "bucket_names" {
  description = "Map of data lake bucket names by zone"
  type        = map(string)
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
