output "dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.dataset.dataset_id
}

output "dataset_self_link" {
  description = "BigQuery dataset self-link"
  value       = google_bigquery_dataset.dataset.self_link
}

output "taxonomy_id" {
  description = "PII taxonomy resource name"
  value       = google_data_catalog_taxonomy.pii_taxonomy.id
}

output "kms_key_name" {
  description = "CMEK key used for BigQuery encryption"
  value       = var.kms_key_name != "" ? var.kms_key_name : try(google_kms_crypto_key.bq_key[0].id, "")
}
