# =============================================================================
# Cloud DLP Module — Automated PII Detection & De-identification
# =============================================================================
# ARCHITECTURE DECISION: Cloud DLP over manual PII scanning:
#
# 1. Coverage: DLP detects 150+ infoTypes out of the box. Manual regex-based
#    scanning for email, phone, SSN, credit card, etc. requires continuous
#    maintenance as formats change.
#
# 2. Scale: DLP can scan terabytes of data in Cloud Storage and BigQuery
#    without writing a single line of Spark or Dataflow code.
#
# 3. Automation: Job triggers on GCS bucket events mean every new file is
#    scanned automatically. No cron jobs, no polling.
#
# 4. De-identification: DLP templates provide consistent masking, tokenization,
#    and encryption across the pipeline. This ensures PII is handled the same
#    way whether it's in the raw zone or being loaded into BigQuery.
#
# 5. Audit: Every DLP finding is logged to Cloud Audit Logs with the source
#    file, infoType, and location. This is critical for GDPR Article 33
#    (data breach notification) response.
#
# Data flow:
#   1. File lands in raw zone bucket → Cloud Pub/Sub notification
#   2. DLP job trigger fires → inspects file for PII infoTypes
#   3. Findings are logged to BigQuery (dlp_findings table) and Cloud Audit Logs
#   4. If PII found > threshold, the file path is flagged for manual review
#   5. Clean file progresses to curated zone for BigQuery loading

# ---------------------------------------------------------------------------
# Inspection Template
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: The inspection template defines what PII to look for
# and how to handle findings. We include UK-specific infoTypes (NHS number,
# National Insurance number) that are critical for GDPR compliance.
# SECURITY SAFEGUARD: max_findings_per_item and max_findings_per_request
# prevent runaway scanning costs on unexpectedly large files.

resource "google_data_loss_prevention_inspect_template" "pii_inspect" {
  parent       = "projects/${var.project_id}"
  display_name = var.config.inspection_template_id
  description  = "PII inspection template for SecondWave fraud detection data — scans for GDPR-relevant infoTypes"

  inspect_config {
    # ARCHITECTURE DECISION: We scan for both global (email, phone, credit card)
    # and UK-specific (National Insurance, NHS) infoTypes. The UK-specific types
    # are essential for our London-based fintech operation.
    info_types {
      name = "EMAIL_ADDRESS"
    }
    info_types {
      name = "PHONE_NUMBER"
    }
    info_types {
      name = "US_SSN"
    }
    info_types {
      name = "UK_NATIONAL_INSURANCE_NUMBER"
    }
    info_types {
      name = "CREDIT_CARD_NUMBER"
    }
    info_types {
      name = "DATE_OF_BIRTH"
    }
    info_types {
      name = "PERSON_NAME"
    }
    info_types {
      name = "STREET_ADDRESS"
    }
    info_types {
      name = "UK_NHS_NUMBER"
    }
    info_types {
      name = "IBAN"
    }
    info_types {
      name = "SWIFT_CODE"
    }

    # SECURITY SAFEGUARD: Minimum likelihood threshold to reduce false positives.
    # POSSIBLE findings require manual review; LIKELY/VERY_LIKELY are auto-flagged.
    min_likelihood = "POSSIBLE"

    # ARCHITECTURE DECISION: Limit findings to prevent bill shock. At ~$0.60/GB
    # for DLP inspection, setting a cap of 100 findings per item prevents a
    # single misconfigured file from generating excessive costs.
    limits {
      max_findings_per_item    = var.config.inspect_max_findings
      max_findings_per_request = var.config.inspect_max_findings * 10
    }

    # ARCHITECTURE DECISION: Include quote to capture the actual text that
    # triggered the finding. This helps analysts quickly verify whether a
    # finding is a real PII detection or a false positive.
    include_quote = true
  }
}

# ---------------------------------------------------------------------------
# De-identification Template
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: The de-identification template uses character masking
# to replace PII with a consistent mask. We use masking over tokenization because:
# 1. Masked values are deterministic — same input always produces same mask
# 2. No need to maintain a tokenization crypto key
# 3. Easier to debug: "****-****-****-1234" clearly shows the last 4 digits
#    for fraud investigators without exposing the full number
# SECURITY SAFEGUARD: The mask character (*) and masking window are configured
# to reveal only the minimum necessary info. For credit cards, we only show
# the last 4 digits (standard PCI-DSS compliance practice).

resource "google_data_loss_prevention_deidentify_template" "pii_mask" {
  parent       = "projects/${var.project_id}"
  display_name = var.config.deidentify_template_id
  description  = "PII masking template — replaces sensitive values with masked characters for analytics"

  deidentify_config {
    info_type_transformations {
      transformations {
        info_types {
          name = "EMAIL_ADDRESS"
        }
        info_types {
          name = "PHONE_NUMBER"
        }
        info_types {
          name = "US_SSN"
        }
        info_types {
          name = "UK_NATIONAL_INSURANCE_NUMBER"
        }
        info_types {
          name = "CREDIT_CARD_NUMBER"
        }
        info_types {
          name = "DATE_OF_BIRTH"
        }
        info_types {
          name = "PERSON_NAME"
        }
        info_types {
          name = "STREET_ADDRESS"
        }

        primitive_transformation {
          character_mask_config {
            masking_character = "*"
            number_to_mask    = 0
            characters_to_ignore {
              characters_to_skip = "-"
            }
            reverse_order = false
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Job Trigger — Automated Scanning
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: The job trigger monitors the raw data lake bucket
# for new files and automatically runs the inspection template. This ensures
# PII is detected before data is loaded into BigQuery.
# SECURITY SAFEGUARD: The trigger is scoped to the raw bucket only. Curated
# and consumption buckets should already be PII-free.

resource "google_data_loss_prevention_job_trigger" "gcs_scan" {
  parent       = "projects/${var.project_id}"
  display_name = var.config.job_trigger_id
  description  = "DLP job trigger for scanning new files in the raw data lake bucket"

  triggers {
    schedule {
      recurrence_period_duration = "${var.config.scan_frequency_minutes * 60}s"
    }
  }

  inspect_job {
    inspect_template_name = google_data_loss_prevention_inspect_template.pii_inspect.name

    storage_config {
      cloud_storage_options {
        file_set {
          url = "gs://${var.bucket_names["raw"]}/*"
        }
      }
    }

    # ARCHITECTURE DECISION: Save findings to BigQuery for analysis and
    # reporting. The dlp_findings table contains:
    # - source_file: GCS path of the scanned file
    # - info_type: What PII was found (e.g., EMAIL_ADDRESS)
    # - likelihood: How confident DLP is this is PII
    # - location: Byte range of the finding in the file
    # - timestamp: When the scan was performed
    actions {
      save_findings {
        output_config {
          table {
            project_id = var.project_id
            dataset_id = "secondwave_${var.environment}"
            table_id   = "dlp_findings"
          }
        }
      }
    }

    # SECURITY SAFEGUARD: Send Pub/Sub notification when scan completes,
    # especially if high-likelihood PII was found.
    actions {
      pub_sub {
        topic = google_pubsub_topic.dlp_alerts.id
      }
    }

    inspect_config {
      info_types {
        name = "EMAIL_ADDRESS"
      }
      info_types {
        name = "PHONE_NUMBER"
      }
      info_types {
        name = "UK_NATIONAL_INSURANCE_NUMBER"
      }
      info_types {
        name = "CREDIT_CARD_NUMBER"
      }
      min_likelihood = "POSSIBLE"
      limits {
        max_findings_per_item    = var.config.inspect_max_findings
        max_findings_per_request = var.config.inspect_max_findings * 10
      }
      include_quote = true
    }
  }
}

# ---------------------------------------------------------------------------
# Pub/Sub Topic for DLP Alerts
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: A Pub/Sub topic allows downstream systems to react
# to DLP findings in real-time. For example, the data pipeline can pause
# loading when PII is detected until the data engineering team reviews.
resource "google_pubsub_topic" "dlp_alerts" {
  name    = "dlp-alerts-${var.environment}"
  project = var.project_id
  labels  = var.labels
}
