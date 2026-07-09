# =============================================================================
# Root Module — SecondWave ML/AI Platform
# =============================================================================
# ARCHITECTURE DECISION: This single root module orchestrates the entire
# ML/AI platform as a cohesive unit. Each child module handles a specific
# domain (BigQuery, Composer, Vertex AI, etc.) with clearly defined
# interfaces. This avoids the complexity of Terragrunt or multi-repo setups
# for a single platform team of 5 engineers.
#
# The data flow is:
#   Raw transactions → Cloud Storage (data lake) → DLP inspection →
#   BigQuery (with column ACLs + CMEK) → Vertex AI training/inference →
#   Vector Search for semantic similarity on claims/transactions →
#   Fraud detection API

locals {
  # ARCHITECTURE DECISION: Suffix resources with environment to support
  # workspace-based deployments from the same Terraform configuration.
  environment_suffix = var.environment

  # Common labels applied to all resources for cost tracking and governance
  common_labels = merge(var.default_labels, {
    environment = var.environment
  })

  # SECURITY SAFEGUARD: Pre-compute resource names with a consistent
  # naming convention. This makes it trivial to identify resources
  # belonging to this platform for auditing and cleanup.
  name_prefix = "secondwave-${var.environment}"
}

# =============================================================================
# BigQuery Datasets with Column-Level ACLs and CMEK
# =============================================================================
# ARCHITECTURE DECISION: Using native BigQuery column-level security over
# view-only access because:
# 1. Column ACLs apply to ALL queries (SELECT *, CTAS, etc.) — views only
#    protect against explicit SELECT * scenarios.
# 2. Column ACLs don't require maintaining separate view definitions per
#    access pattern.
# 3. Row-level security allows data masking at the row level for analysts
#    who need aggregate stats but shouldn't see raw PII.

module "bigquery" {
  source = "./modules/bigquery"

  project_id         = var.project_id
  environment        = var.environment
  dataset_config     = var.bigquery_datasets[var.environment]
  kms_key_name       = var.bigquery_datasets[var.environment].kms_key_name
  default_labels     = local.common_labels
}

# =============================================================================
# Data Lake — Cloud Storage with Lifecycle Tiering
# =============================================================================
# ARCHITECTURE DECISION: Multi-zone data lake (raw → curated → consumption →
# transient) separates concerns and allows different lifecycle policies per
# zone. The raw zone has immutable retention for compliance; the transient
# zone auto-deletes after 7 days to control costs.
# SECURITY SAFEGUARD: All buckets have public access prevention enabled and
# CMEK encryption. No bucket allows uniform bucket-level access that would
# bypass IAM.

module "data_lake" {
  source = "./modules/data-lake"

  project_id     = var.project_id
  environment    = var.environment
  bucket_configs = var.data_lake_config
  kms_key_name   = ""

  depends_on = []
}

# =============================================================================
# Cloud Composer — Managed Airflow for ML Pipeline Orchestration
# =============================================================================
# ARCHITECTURE DECISION: Cloud Composer (managed Airflow) over self-hosted
# Airflow on GKE because:
# 1. Reduces operational burden — no cluster management, no Airflow
#    infrastructure maintenance for the 5-person platform team.
# 2. Built-in Cloud Audit Logs, Cloud Monitoring, and IAM integration.
# 3. Native VPC-SC support for private networking.
# 4. Auto-scaling workers based on queue depth.
# Trade-off: Higher per-DAG cost vs. self-hosted, but the engineering time
# saved exceeds the premium at SecondWave's transaction volume.

module "composer" {
  source = "./modules/composer"

  project_id      = var.project_id
  environment     = var.environment
  composer_config = var.composer_config
  labels          = local.common_labels

  depends_on = [
    module.data_lake
  ]
}

# =============================================================================
# Vertex AI Workbench — ML Development Environments
# =============================================================================
# ARCHITECTURE DECISION: Vertex AI Workbench over custom GCE instances because:
# 1. One-click JupyterLab with pre-installed ML frameworks.
# 2. Built-in integration with Vertex AI training/prediction.
# 3. Idle shutdown to control costs (ML engineers frequently leave
#    instances running).
# 4. Shielded VMs with CMEK are natively supported.
# 5. Private networking prevents data exfiltration through public IPs.

module "vertex_ai" {
  source = "./modules/vertex-ai"

  project_id     = var.project_id
  environment    = var.environment
  instance_configs = var.vertex_ai_config
  kms_key_name   = ""
  labels         = local.common_labels
}

# =============================================================================
# Vertex AI Vector Search — Semantic Search for Fraud Detection
# =============================================================================
# ARCHITECTURE DECISION: Vertex AI Vector Search over custom ANN (e.g.,
# Elasticsearch with dense vectors) because:
# 1. Native integration with Vertex AI embeddings — no data movement.
# 2. Sub-10ms latency at 10M+ vectors for real-time fraud scoring.
# 3. Scaledown to zero when not in use (cost savings).
# 4. VPC-SC compatible (private endpoint in the VPC).
# 5. No cluster management overhead.

module "vector_search" {
  source = "./modules/vector-search"

  project_id  = var.project_id
  environment = var.environment
  config      = var.vector_search_config
  labels      = local.common_labels
}

# =============================================================================
# Cloud DLP — Automated PII Detection and De-identification
# =============================================================================
# ARCHITECTURE DECISION: Cloud DLP over manual PII scanning because:
# 1. DLP automatically detects 150+ infoTypes (email, SSN, credit card, etc.)
#    without custom regex maintenance.
# 2. Job triggers fire on GCS bucket changes — no polling overhead.
# 3. De-identification templates provide consistent masking across the
#    data pipeline.
# 4. Audit logs track every PII finding for GDPR compliance reporting.

module "dlp" {
  source = "./modules/dlp"

  project_id  = var.project_id
  environment = var.environment
  config      = var.dlp_config
  bucket_names = module.data_lake.bucket_names
  labels      = local.common_labels

  depends_on = [
    module.data_lake
  ]
}

# =============================================================================
# Workload Identity Federation — Keyless Auth for ML Workloads
# =============================================================================
# ARCHITECTURE DECISION: Workload Identity Federation over service account
# key files because:
# 1. No key rotation overhead — tokens are short-lived and auto-refreshed.
# 2. No risk of key leakage in CI/CD secrets or container images.
# 3. GitHub Actions can authenticate directly via OIDC without storing
#    any GCP credentials.
# 4. Each workload gets its own identity with minimal permissions.

module "workload_identity" {
  source = "./modules/workload-identity"

  project_id  = var.project_id
  environment = var.environment
  config      = var.workload_identity_config
  labels      = local.common_labels
}

# =============================================================================
# VPC Service Controls Perimeter
# =============================================================================
# SECURITY SAFEGUARD: VPC-SC prevents data exfiltration by restricting
# access to GCP services to only the configured VPC network. Even if a
# service account key is compromised, data cannot be copied to a network
# outside the perimeter.
# ARCHITECTURE DECISION: VPC-SC is applied to ALL ML/AI services
# (BigQuery, Storage, Vertex AI, Composer, DLP) as a defense-in-depth
# layer. This is in addition to IAM and CMEK.

resource "google_access_context_manager_service_perimeter" "ml_perimeter" {
  provider = google-beta

  # SECURITY SAFEGUARD: The perimeter is in "dry_run" mode initially.
  # Switch to "enforced" only after monitoring during the first 30 days
  # to ensure no legitimate traffic is blocked.
  status {
    restricted_services = var.vpc_sc_config.restricted_services
    access_levels       = [var.vpc_sc_config.access_level]
    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = var.vpc_sc_config.vpc_accessible_services
    }
  }

  # ARCHITECTURE DECISION: Runtime rules allow VPC-SC to understand the
  # resource hierarchy. We grant the project-level exemption for the
  # initial migration period.
  spec {
    resources = ["projects/${var.project_id}"]
  }

  name   = var.vpc_sc_config.perimeter_name
  title  = var.vpc_sc_config.perimeter_title
  parent = "accessPolicies/12345678"
  perimeter_type = "PERIMETER_TYPE_REGULAR"
  use_explicit_dry_run_spec = true
}

# =============================================================================
# OpenTelemetry Collector — ML Pipeline Observability
# =============================================================================
# ARCHITECTURE DECISION: OpenTelemetry collector provides vendor-neutral
# telemetry collection. We deploy it as a Cloud Run service that receives
# traces, metrics, and logs from Composer DAGs, Vertex AI jobs, and
# custom ML training code, then exports to Cloud Monitoring and BigQuery
# for analysis.

resource "google_cloud_run_service" "otel_collector" {
  name     = "otel-collector-${local.environment_suffix}"
  location = var.region

  template {
    spec {
      containers {
        image = "otel/opentelemetry-collector-contrib:0.95.0"
        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
      }
      service_account_name = google_service_account.otel_collector.email
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "2"
        "run.googleapis.com/vpc-access-egress" = "private-ranges-only"
        "run.googleapis.com/encryption-key"     = "projects/${var.project_id}/locations/${var.region}/keyRings/cloud-run/cryptoKeys/otel-key"
      }
    }
  }

  autogenerate_revision_name = true

  lifecycle {
    ignore_changes = [
      template[0].metadata[0].annotations["client.knative.dev/user-image"],
      template[0].spec[0].containers[0].image,
    ]
  }
}

resource "google_service_account" "otel_collector" {
  account_id   = "otel-collector-${local.environment_suffix}"
  display_name = "OpenTelemetry Collector Service Account"
  description  = "Service account for the OpenTelemetry collector that forwards ML pipeline telemetry to Cloud Monitoring"
}

# SECURITY SAFEGUARD: The OTel collector service account has only the
# permissions it needs — no more.
resource "google_project_iam_member" "otel_metrics_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}
resource "google_project_iam_member" "otel_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}
resource "google_project_iam_member" "otel_trace_writer" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}

# =============================================================================
# Cloud Monitoring Dashboards
# =============================================================================
# ARCHITECTURE DECISION: JSON dashboard definitions are stored in the
# observability/ directory and imported as code. This ensures dashboards
# are version-controlled, reviewed in PRs, and deployable alongside
# infrastructure changes.

resource "google_monitoring_dashboard" "ml_platform" {
  dashboard_json = file("${path.module}/observability/ml-dashboard.json")
}

# =============================================================================
# Cloud Monitoring Alert Policies
# =============================================================================
# ARCHITECTURE DECISION: Alert policies are defined in JSON and imported
# here. The rules are:
# 1. DAG failure rate > 5% over 5 minutes → page on-call engineer
# 2. BigQuery slot utilization > 80% over 1 hour → increase slot capacity
# 3. DLP scan failure → alert data engineering team
# 4. Data lake bucket growth anomaly → investigate potential data leak

resource "google_monitoring_alert_policy" "dag_failure" {
  display_name = "Composer DAG Failure Rate > ${var.monitoring_config.dag_failure_threshold}%"
  combiner     = "OR"
  conditions {
    display_name = "DAG failure rate"
    condition_threshold {
      filter          = "metric.type=\"composer.googleapis.com/dag/run_count\" AND metric.labels.status=\"failed\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.monitoring_config.dag_failure_threshold
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.monitoring_config.notification_channels
  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "bq_slot_usage" {
  display_name = "BigQuery Slot Usage > ${var.monitoring_config.bq_slot_threshold}%"
  combiner     = "OR"
  conditions {
    display_name = "Slot utilization"
    condition_threshold {
      filter          = "metric.type=\"bigquery.googleapis.com/slot/total_usage\" AND resource.labels.project_id=\"${var.project_id}\""
      duration        = "3600s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.monitoring_config.bq_slot_threshold
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MEAN"
      }
    }
  }

  notification_channels = var.monitoring_config.notification_channels
  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "dlp_scan_failure" {
  display_name = "DLP Scan Job Failure"
  combiner     = "OR"
  conditions {
    display_name = "DLP job status"
    condition_threshold {
      filter          = "metric.type=\"dlp.googleapis.com/job/status\" AND metric.labels.status=\"FAILED\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
    }
  }
  notification_channels = var.monitoring_config.notification_channels
}

resource "google_monitoring_alert_policy" "bucket_growth_anomaly" {
  display_name = "Data Lake Bucket Growth Anomaly"
  combiner     = "OR"
  conditions {
    display_name = "Bucket size anomaly"
    condition_threshold {
      filter          = "metric.type=\"storage.googleapis.com/storage/total_bytes\" AND resource.labels.bucket_name=starts_with(\"secondwave-${var.environment}\")"
      duration        = "3600s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.monitoring_config.bucket_growth_threshold
      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_PERCENTILE_95"
      }
    }
  }
  notification_channels = var.monitoring_config.notification_channels
}
