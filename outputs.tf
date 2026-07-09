# =============================================================================
# Outputs — SecondWave ML/AI Platform
# =============================================================================

output "bigquery_dataset_ids" {
  description = "BigQuery dataset IDs created per environment"
  value = {
    dev     = module.bigquery.dataset_id
    staging = module.bigquery.dataset_id
    prod    = module.bigquery.dataset_id
  }
}

output "composer_airflow_uri" {
  description = "Cloud Composer Airflow web UI URI"
  value       = module.composer.airflow_uri
  sensitive   = true
}

output "vertex_ai_notebook_names" {
  description = "Vertex AI Workbench notebook instance names"
  value       = module.vertex_ai.instance_names
}

output "vector_search_index_id" {
  description = "Vertex AI Vector Search index resource name"
  value       = module.vector_search.index_id
}

output "data_lake_bucket_names" {
  description = "Data lake Cloud Storage bucket names by zone"
  value       = module.data_lake.bucket_names
}

output "dlp_job_names" {
  description = "Cloud DLP job trigger names"
  value       = module.dlp.job_trigger_names
}

output "workload_identity_pools" {
  description = "Workload Identity Federation pool IDs"
  value       = module.workload_identity.pool_ids
}

output "otel_collector_url" {
  description = "OpenTelemetry Collector Cloud Run service URL"
  value       = google_cloud_run_service.otel_collector.status[0].url
}
