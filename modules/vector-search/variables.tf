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

variable "config" {
  description = "Vector Search index configuration"
  type = object({
    index_name            = string
    description           = string
    dimensions            = number
    approximate_neighbors = number
    distance_measure_type = string
    algorithm_config      = string
    network               = string
    contents_delta_uri    = optional(string, "")
    is_complete_overwrite  = optional(bool, false)
    leaf_node_embedding_count    = optional(number, 25000)
    leaf_nodes_to_search_percent = optional(number, 5)
    shard_size                    = optional(string, "SHARD_SIZE_SMALL")
    index_update_method           = optional(string, "BATCH_UPDATE")
    deployed_machine_type         = optional(string, "n1-standard-4")
    min_replica_count             = optional(number, 1)
    max_replica_count             = optional(number, 5)
  })
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
