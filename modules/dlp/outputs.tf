output "inspection_template_id" {
  description = "DLP inspection template resource name"
  value       = google_data_loss_prevention_inspect_template.pii_inspect.id
}

output "deidentify_template_id" {
  description = "DLP de-identification template resource name"
  value       = google_data_loss_prevention_deidentify_template.pii_mask.id
}

output "job_trigger_names" {
  description = "DLP job trigger display names"
  value       = [google_data_loss_prevention_job_trigger.gcs_scan.display_name]
}

output "pubsub_topic" {
  description = "Pub/Sub topic for DLP alert notifications"
  value       = google_pubsub_topic.dlp_alerts.id
}
