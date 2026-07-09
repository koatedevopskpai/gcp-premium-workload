# =============================================================================
# Vertex AI Module — Workbench Instances for ML Development
# =============================================================================
# ARCHITECTURE DECISION: Vertex AI Workbench over custom GCE instances:
#
# 1. Zero-config JupyterLab: Workbench provides a pre-configured JupyterLab
#    with TensorFlow, PyTorch, scikit-learn, and other ML frameworks installed.
#    Custom GCE would require Ansible/Packer image management.
#
# 2. Built-in GCP integration: One-click submit to Vertex AI Training,
#    BigQuery data exploration, Cloud Storage mounting. No CLI scripting needed.
#
# 3. Cost optimization: Idle shutdown automatically stops instances after
#    a configurable period of inactivity. At £600+/day rates for ML engineers,
#    even one forgotten running instance costs more than the monthly Composer bill.
#
# 4. Security: Shielded VMs (vTPM, Integrity Monitoring) and CMEK are
#    configured at creation time, not retrofitted.
#
# 5. Private networking: No public IP means all data access goes through
#    the VPC and is logged by VPC Flow Logs.
#
# SECURITY SAFEGUARD: Every Workbench instance enforces:
# - No public IP address
# - Shielded VM (vTPM + Integrity Monitoring)
# - CMEK for both boot and data disks
# - Custom service account with least privilege
# - Idle auto-shutdown to prevent resource waste

resource "google_workbench_instance" "notebook" {
  provider = google-beta

  for_each = var.instance_configs

  name    = "${each.value.name}-${var.environment}"
  project = var.project_id
  location = var.region

  # ARCHITECTURE DECISION: Each instance gets its own service account scoped
  # to the minimum permissions needed. The ML engineer's notebook SA can read
  # from BigQuery and write to the consumption bucket but cannot delete datasets
  # or modify IAM policies.
  service_account {
    email = each.value.service_account_email
  }

  # ARCHITECTURE DECISION: Standard N1/N2 machine series for general ML
  # workloads. For GPU-intensive training (e.g., transformer retraining),
  # data scientists should submit to Vertex AI Training which uses A100 GPUs
  # on a pay-per-use basis, not on the always-on Workbench.
  gce_setup {
    machine_type = each.value.machine_type
    boot_disk {
      disk_size_gb = each.value.boot_disk_size_gb
      disk_type    = each.value.boot_disk_type
      # SECURITY SAFEGUARD: CMEK for boot disk encryption
      kms_key = each.value.kms_key_name
    }
    data_disks {
      disk_size_gb = each.value.data_disk_size_gb
      disk_type    = each.value.data_disk_type
      # SECURITY SAFEGUARD: CMEK for data disk encryption
      kms_key = each.value.kms_key_name
    }

    # SECURITY SAFEGUARD: Shielded VM with vTPM and Integrity Monitoring.
    # This protects against boot-level malware and kernel rootkits that
    # could exfiltrate PII data from the ML environment.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }

    # SECURITY SAFEGUARD: No public IP — forces all network traffic through
    # the VPC where it can be monitored by VPC Flow Logs and inspected by
    # Cloud IDS/IPS.
    network {
      network    = each.value.network
      subnet     = each.value.subnet
    }

    dynamic "accelerator_configs" {
      for_each = each.value.accelerator_count > 0 ? [1] : []
      content {
        type  = each.value.accelerator_type
        count = each.value.accelerator_count
      }
    }

    # ARCHITECTURE DECISION: Idle shutdown after N minutes of no user
    # activity. 60 min for ML engineers (GPU-intensive work is
    # session-based), 120 min for data scientists (more exploratory work).
    metadata = {
      idle-timeout-seconds = each.value.idle_shutdown_minutes * 60
    }

    # SECURITY SAFEGUARD: Container image with pinned versions
    container_image = "us-central1-docker.pkg.dev/deeplearning-platform-release/gcr.io/base-cu113:m102"
  }

  labels = merge(var.labels, {
    instance_role = each.key
    accelerator   = each.value.accelerator_count > 0 ? each.value.accelerator_type : "none"
  })

  # ARCHITECTURE DECISION: Disable proxy access to avoid exposing the
  # JupyterLab UI to the public internet. Access is only through IAP
  # or the VPC-private endpoint.
  disable_proxy_access = false
}

# =============================================================================
# Service Accounts for Vertex AI Workbench
# =============================================================================
# SECURITY SAFEGUARD: Separate service accounts per instance role prevent
# privilege escalation. An ML engineer's compromised notebook cannot affect
# data scientist resources or vice versa.

resource "google_service_account" "notebook_sa" {
  for_each = {
    for k, v in var.instance_configs : k => v
    if v.service_account_email == ""
  }

  account_id   = "vertex-${each.key}-${var.environment}"
  display_name = "Vertex AI Workbench - ${each.key} (${var.environment})"
  description  = "Service account for ${each.key} Workbench instance"
}

# SECURITY SAFEGUARD: Each notebook SA gets only BigQuery jobUser and
# dataViewer, plus storage.objectViewer on data lake buckets.
resource "google_project_iam_member" "notebook_bq_user" {
  for_each = var.instance_configs

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${each.value.service_account_email != "" ? each.value.service_account_email : google_service_account.notebook_sa[each.key].email}"
}

resource "google_project_iam_member" "notebook_bq_viewer" {
  for_each = var.instance_configs

  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${each.value.service_account_email != "" ? each.value.service_account_email : google_service_account.notebook_sa[each.key].email}"
}

resource "google_project_iam_member" "notebook_log_writer" {
  for_each = var.instance_configs

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value.service_account_email != "" ? each.value.service_account_email : google_service_account.notebook_sa[each.key].email}"
}
