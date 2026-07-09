output "composer_environment_id" {
  description = "Composer environment resource ID"
  value       = google_composer_environment.composer.id
}

output "airflow_uri" {
  description = "Airflow web UI URI (VPC-private)"
  value       = google_composer_environment.composer.config[0].airflow_uri
  sensitive   = true
}

output "dag_gcs_prefix" {
  description = "GCS prefix where DAG files are synced"
  value       = google_composer_environment.composer.config[0].dag_gcs_prefix
}

output "gke_cluster" {
  description = "GKE cluster name hosting the Composer workloads"
  value       = google_composer_environment.composer.config[0].gke_cluster
}
