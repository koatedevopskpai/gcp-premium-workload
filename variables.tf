# =============================================================================
# Variables — SecondWave ML/AI Platform
# =============================================================================

# ---------------------------------------------------------------------------
# Project & Environment
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "GCP project ID for the ML/AI platform"
  type        = string

  # ARCHITECTURE DECISION: Project-level isolation means one project per
  # environment (dev/staging/prod). This gives clear IAM boundaries and
  # avoids accidental cross-environment data access.
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "europe-west2"

  # ARCHITECTURE DECISION: europe-west2 (London) for UK data residency.
  # Ensures GDPR compliance by keeping all PII data within UK borders.
}

variable "environment" {
  description = "Deployment environment label (dev, staging, prod)"
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# BigQuery
# ---------------------------------------------------------------------------
variable "bigquery_datasets" {
  description = "BigQuery dataset configurations per environment"
  type = map(object({
    dataset_id       = string
    description      = string
    location         = string
    default_ttl_days = number
    kms_key_name     = string
    column_acls = map(object({
      sensitive_columns = list(string)
      authorized_group  = string
    }))
    row_access_policies = map(object({
      filter_column   = string
      masked_value    = string
      authorized_user = string
    }))
  }))
  default = {
    dev = {
      dataset_id       = "secondwave_dev"
      description      = "SecondWave development dataset — synthetic fraud data"
      location         = "europe-west2"
      default_ttl_days = 30
      kms_key_name     = ""
      column_acls = {
        pii_restricted = {
          sensitive_columns = ["email", "phone_number", "national_id", "credit_card"]
          authorized_group  = "group:data-engineering@secondwave.com"
        }
      }
      row_access_policies = {
        masked_pii = {
          filter_column   = "pii_visible"
          masked_value    = "MASKED"
          authorized_user = "user:analyst@secondwave.com"
        }
      }
    }
    staging = {
      dataset_id       = "secondwave_staging"
      description      = "SecondWave staging dataset — production-like synthetic data"
      location         = "europe-west2"
      default_ttl_days = 90
      kms_key_name     = ""
      column_acls = {
        pii_restricted = {
          sensitive_columns = ["email", "phone_number", "national_id", "credit_card", "dob"]
          authorized_group  = "group:data-engineering@secondwave.com"
        }
      }
      row_access_policies = {
        masked_pii = {
          filter_column   = "pii_visible"
          masked_value    = "MASKED"
          authorized_user = "user:analyst@secondwave.com"
        }
      }
    }
    prod = {
      dataset_id       = "secondwave_prod"
      description      = "SecondWave production dataset — live fraud detection data"
      location         = "europe-west2"
      default_ttl_days = 365
      kms_key_name     = "projects/secondwave-prod/locations/europe-west2/keyRings/bq/cryptoKeys/bq-key"
      column_acls = {
        pii_restricted = {
          sensitive_columns = ["email", "phone_number", "national_id", "credit_card", "dob", "bank_account"]
          authorized_group  = "group:data-engineering@secondwave.com"
        }
        executive = {
          sensitive_columns = ["revenue_impact", "investigation_notes"]
          authorized_group  = "group:executives@secondwave.com"
        }
      }
      row_access_policies = {
        masked_pii = {
          filter_column   = "pii_visible"
          masked_value    = "MASKED"
          authorized_user = "user:analyst@secondwave.com"
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Cloud Composer
# ---------------------------------------------------------------------------
variable "composer_config" {
  description = "Cloud Composer 2 configuration"
  type = object({
    environment_size   = string
    scheduler_count    = number
    worker_count       = number
    web_server_count   = number
    airflow_version    = string
    airflow_config_overrides = map(string)
    env_variables      = map(string)
    network            = string
    subnetwork         = string
    kms_key_name       = string
    service_account_email = string
  })
  default = {
    environment_size = "ENVIRONMENT_SIZE_SMALL"
    scheduler_count  = 1
    worker_count     = 3
    web_server_count = 1
    airflow_version  = "2.9.1"
    airflow_config_overrides = {
      "core-dags_are_paused_at_creation" = "True"
    }
    env_variables = {
      "SECONDWAVE_ENV" = "dev"
    }
    network             = "projects/secondwave-dev/global/networks/vpc-main"
    subnetwork          = "projects/secondwave-dev/regions/europe-west2/subnetworks/subnet-composer"
    kms_key_name        = ""
    service_account_email = ""
  }
}

# ---------------------------------------------------------------------------
# Vertex AI
# ---------------------------------------------------------------------------
variable "vertex_ai_config" {
  description = "Vertex AI Workbench instance configurations"
  type = map(object({
    name                = string
    machine_type        = string
    accelerator_type    = string
    accelerator_count   = number
    boot_disk_size_gb   = number
    boot_disk_type      = string
    data_disk_size_gb   = number
    data_disk_type      = string
    network             = string
    subnet              = string
    kms_key_name        = string
    service_account_email = string
    idle_shutdown_minutes = number
  }))
  default = {
    ml-engineer = {
      name                  = "ml-engineer-wb"
      machine_type          = "n1-standard-8"
      accelerator_type      = "NVIDIA_TESLA_T4"
      accelerator_count     = 1
      boot_disk_size_gb     = 100
      boot_disk_type        = "PD_SSD"
      data_disk_size_gb     = 500
      data_disk_type        = "PD_SSD"
      network               = "projects/secondwave-dev/global/networks/vpc-main"
      subnet                = "projects/secondwave-dev/regions/europe-west2/subnetworks/subnet-vertex"
      kms_key_name          = ""
      service_account_email = ""
      idle_shutdown_minutes = 60
    }
    data-scientist = {
      name                  = "data-scientist-wb"
      machine_type          = "n1-standard-4"
      accelerator_type      = "NVIDIA_TESLA_T4"
      accelerator_count     = 0
      boot_disk_size_gb     = 100
      boot_disk_type        = "PD_SSD"
      data_disk_size_gb     = 200
      data_disk_type        = "PD_SSD"
      network               = "projects/secondwave-dev/global/networks/vpc-main"
      subnet                = "projects/secondwave-dev/regions/europe-west2/subnetworks/subnet-vertex"
      kms_key_name          = ""
      service_account_email = ""
      idle_shutdown_minutes = 120
    }
  }
}

# ---------------------------------------------------------------------------
# Vector Search
# ---------------------------------------------------------------------------
variable "vector_search_config" {
  description = "Vertex AI Vector Search index configuration"
  type = object({
    index_name            = string
    description           = string
    dimensions            = number
    approximate_neighbors = number
    distance_measure_type = string
    algorithm_config      = string
    network               = string
  })
  default = {
    index_name            = "fraud-semantic-search"
    description           = "Vector index for semantic search on fraud transaction embeddings"
    dimensions            = 768
    approximate_neighbors = 150
    distance_measure_type = "DOT_PRODUCT_DISTANCE"
    algorithm_config      = "tree_ah"
    network               = "projects/secondwave-dev/global/networks/vpc-main"
  }
}

# ---------------------------------------------------------------------------
# Data Lake (Cloud Storage)
# ---------------------------------------------------------------------------
variable "data_lake_config" {
  description = "Cloud Storage data lake bucket configurations"
  type = map(object({
    name_prefix       = string
    location          = string
    storage_class     = string
    retention_days    = number
    versioning        = bool
    lifecycle_rules = list(object({
      age     = number
      storage = string
    }))
  }))
  default = {
    raw = {
      name_prefix    = "secondwave-raw"
      location       = "europe-west2"
      storage_class  = "STANDARD"
      retention_days = 7
      versioning     = true
      lifecycle_rules = [
        { age = 30, storage = "NEARLINE" },
        { age = 90, storage = "COLDLINE" },
        { age = 365, storage = "ARCHIVE" },
      ]
    }
    curated = {
      name_prefix    = "secondwave-curated"
      location       = "europe-west2"
      storage_class  = "STANDARD"
      retention_days = 0
      versioning     = true
      lifecycle_rules = [
        { age = 90, storage = "COLDLINE" },
      ]
    }
    consumption = {
      name_prefix    = "secondwave-consumption"
      location       = "europe-west2"
      storage_class  = "STANDARD"
      retention_days = 0
      versioning     = true
      lifecycle_rules = []
    }
    transient = {
      name_prefix    = "secondwave-transient"
      location       = "europe-west2"
      storage_class  = "STANDARD"
      retention_days = 0
      versioning     = false
      lifecycle_rules = [
        { age = 7, storage = "DELETE" },
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Cloud DLP
# ---------------------------------------------------------------------------
variable "dlp_config" {
  description = "Cloud DLP inspection and de-identification configuration"
  type = object({
    inspection_template_id      = string
    deidentify_template_id      = string
    job_trigger_id              = string
    scan_frequency_minutes      = number
    inspect_max_findings        = number
    inspection_targets          = list(string)
  })
  default = {
    inspection_template_id = "secondwave-pii-inspect"
    deidentify_template_id = "secondwave-pii-mask"
    job_trigger_id         = "secondwave-dlp-trigger"
    scan_frequency_minutes = 1440
    inspect_max_findings   = 100
    inspection_targets     = [
      "EMAIL_ADDRESS",
      "PHONE_NUMBER",
      "US_SSN",
      "UK_NATIONAL_INSURANCE_NUMBER",
      "CREDIT_CARD_NUMBER",
      "DATE_OF_BIRTH",
      "PERSON_NAME",
      "STREET_ADDRESS",
    ]
  }
}

# ---------------------------------------------------------------------------
# Workload Identity
# ---------------------------------------------------------------------------
variable "workload_identity_config" {
  description = "Workload Identity Federation pool and provider configurations"
  type = map(object({
    pool_id               = string
    provider_id           = string
    issuer_uri            = string
    allowed_audiences     = list(string)
    attribute_mapping     = map(string)
    service_account_email = string
    attribute_condition   = string
  }))
  default = {
    github-actions = {
      pool_id               = "github-actions-pool"
      provider_id           = "github-actions-provider"
      issuer_uri            = "https://token.actions.githubusercontent.com"
      allowed_audiences     = ["https://github.com/secondwave"]
      attribute_mapping = {
        "google.subject"       = "assertion.sub"
        "attribute.repository" = "assertion.repository"
      }
      service_account_email = ""
      attribute_condition   = "assertion.repository == 'secondwave/fraud-detection-platform'"
    }
    vertex-ai = {
      pool_id               = "vertex-ai-pool"
      provider_id           = "vertex-ai-provider"
      issuer_uri            = "https://accounts.google.com"
      allowed_audiences     = []
      attribute_mapping = {
        "google.subject"       = "assertion.sub"
        "attribute.google_uid" = "assertion.google.uid"
      }
      service_account_email = ""
      attribute_condition   = ""
    }
  }
}

# ---------------------------------------------------------------------------
# VPC Service Controls
# ---------------------------------------------------------------------------
variable "vpc_sc_config" {
  description = "VPC Service Controls perimeter configuration"
  type = object({
    perimeter_name            = string
    perimeter_title           = string
    restricted_services       = list(string)
    access_level              = string
    vpc_accessible_services   = list(string)
  })
  default = {
    perimeter_name      = "secondwave-ml-perimeter"
    perimeter_title     = "SecondWave ML/AI Perimeter"
    restricted_services = [
      "bigquery.googleapis.com",
      "storage.googleapis.com",
      "aiplatform.googleapis.com",
      "composer.googleapis.com",
      "dlp.googleapis.com",
    ]
    access_level = "accessPolicies/12345678/accessLevels/trusted_employees"
    vpc_accessible_services = [
      "bigquery.googleapis.com",
      "storage.googleapis.com",
      "aiplatform.googleapis.com",
    ]
  }
}

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------
variable "default_labels" {
  description = "Default resource labels"
  type        = map(string)
  default = {
    application  = "secondwave-fraud-detection"
    environment  = "dev"
    cost-center  = "ml-platform"
    managed-by   = "terraform"
    data-classification = "pii-sensitive"
  }
}

# ---------------------------------------------------------------------------
# Cloud Monitoring
# ---------------------------------------------------------------------------
variable "monitoring_config" {
  description = "Cloud Monitoring alert policies configuration"
  type = object({
    notification_channels = list(string)
    dag_failure_threshold = number
    bq_slot_threshold     = number
    bucket_growth_threshold = number
  })
  default = {
    notification_channels   = []
    dag_failure_threshold   = 5
    bq_slot_threshold       = 80
    bucket_growth_threshold = 50
  }
}
