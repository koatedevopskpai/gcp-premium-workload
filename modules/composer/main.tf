# =============================================================================
# Cloud Composer Module — Managed Airflow for ML Pipeline Orchestration
# =============================================================================
# ARCHITECTURE DECISION: Cloud Composer (managed Airflow) over self-hosted
# Airflow on GKE:
#
# 1. Operational burden: A 5-person platform team cannot afford to maintain
#    Airflow infrastructure (PostgreSQL, Redis, web server, scheduler,
#    workers, Flower). Composer handles all of this.
#
# 2. Compliance: Composer integrates natively with VPC-SC, CMEK, and
#    Cloud Audit Logs. Self-hosted Airflow would require manual integration.
#
# 3. Observability: Built-in Cloud Monitoring dashboards for DAG runs,
#    task duration, and queue depth. Self-hosted would need custom exporters.
#
# 4. Scaling: Composer auto-scales workers based on Celery queue depth.
#    Self-hosted requires manual configuration of Horizontal Pod Autoscaler.
#
# 5. Cost: At SecondWave's current scale (~5,000 DAG runs/day), Composer is
#    ~$800/month vs. ~$300/month for self-hosted. The $500 premium is less
#    than 2 hours of a platform engineer's time per month — and Composer
#    saves far more than 2 hours of maintenance time.
#
# SECURITY SAFEGUARD: Composer is configured with:
# - Private IP (no public endpoint)
# - CMEK for encryption
# - Service account with least privilege (no cloud-platform role)
# - VPC-SC integration

resource "google_composer_environment" "composer" {
  provider = google-beta

  name    = "secondwave-composer-${var.environment}"
  project = var.project_id
  region  = var.composer_config.region

  labels = var.labels

  config {
    software_config {
      image_version = var.composer_config.airflow_version

      airflow_config_overrides = var.composer_config.airflow_config_overrides

      env_variables = merge(var.composer_config.env_variables, {
        SECONDWAVE_ENV     = var.environment
        BQ_DATASET         = "secondwave_${var.environment}"
        DATA_LAKE_BUCKET   = "gs://secondwave-raw-${var.environment}"
      })
    }

    node_config {
      network         = var.composer_config.network
      subnetwork      = var.composer_config.subnetwork

      # SECURITY SAFEGUARD: Private IP only — no public IP addresses on
      # Composer nodes. All network egress goes through VPC and Cloud NAT.
      ip_allocation_policy {
        use_ip_aliases = true
      }

      service_account = var.composer_config.service_account_email

      # SECURITY SAFEGUARD: Disk encryption with CMEK key
      disk_encryption_key {
        kms_key_name = var.composer_config.kms_key_name
      }
    }

    # ARCHITECTURE DECISION: Private environment with web server access
    # control. The Airflow UI is only accessible from the VPC network,
    # not from the public internet.
    private_environment_config {
      enable_private_endpoint = true
      cloud_sql_ipv4_cidr_block = "10.20.0.0/24"
      web_server_ipv4_cidr_block = "10.21.0.0/24"
    }

    # SECURITY SAFEGUARD: Web server access control — only allow traffic
    # from the VPC network
    web_server_network_access_control {
      allowed_ip_range {
        value     = var.composer_config.network_cidr
        description = "VPC network access"
      }
    }

    # ARCHITECTURE DECISION: Workload-based scaling with configurable
    # scheduler and worker counts. This allows fine-tuning for batch
    # ML pipeline workloads vs. real-time inference orchestration.
    workloads_config {
      scheduler {
        cpu        = 0.5
        memory_gb = 2
        storage_gb = 1
        count     = var.composer_config.scheduler_count
      }
      web_server {
        cpu        = 0.5
        memory_gb = 2
        storage_gb = 1
      }
      worker {
        cpu        = 1
        memory_gb = 3
        storage_gb = 2
        min_count = 1
        max_count = 10
      }
    }

    environment_size = var.composer_config.environment_size

    # SECURITY SAFEGUARD: Master authorized networks — only Terraform
    # operator IP range can access the Composer API for deployments
    master_authorized_networks_config {
      enabled = true
      cidr_blocks {
        display_name = "terraform-operator"
        cidr_block   = var.terraform_operator_cidr
      }
    }
  }

  depends_on = []
}

# =============================================================================
# Composer Service Account IAM
# =============================================================================
# SECURITY SAFEGUARD: The Composer SA gets only the permissions it needs:
# - Data Lake: objectViewer (read) or objectAdmin (write) depending on zone
# - BigQuery: jobUser (to submit queries) + dataViewer (to read tables)
# - No cloud-platform, no project-wide editor/owner

resource "google_project_iam_member" "composer_bq_job_user" {
  count   = var.composer_config.service_account_email != "" ? 1 : 0
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.composer_config.service_account_email}"
}

resource "google_project_iam_member" "composer_bq_data_viewer" {
  count   = var.composer_config.service_account_email != "" ? 1 : 0
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${var.composer_config.service_account_email}"
}

resource "google_project_iam_member" "composer_log_writer" {
  count   = var.composer_config.service_account_email != "" ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${var.composer_config.service_account_email}"
}

resource "google_project_iam_member" "composer_metric_writer" {
  count   = var.composer_config.service_account_email != "" ? 1 : 0
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${var.composer_config.service_account_email}"
}
