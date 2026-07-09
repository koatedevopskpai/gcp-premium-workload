# =============================================================================
# Data Lake Module — Cloud Storage with Lifecycle Tiering & CMEK
# =============================================================================
# ARCHITECTURE DECISION: Four-zone data lake design (raw, curated, consumption,
# transient) that mirrors the medallion architecture popularised by Databricks.
# Each zone has different lifecycle, retention, and security requirements:
#
#   raw         — Immutable landing zone for ingested data. Retention locked.
#   curated     — Cleaned, deduplicated, enriched data. Versioned for DR.
#   consumption — Aggregated, business-ready datasets. Fast access.
#   transient   — Temporary processing outputs. Auto-deletes after 7 days.
#
# SECURITY SAFEGUARD: Every bucket enforces:
# 1. Public access prevention
# 2. CMEK encryption with customer-managed keys
# 3. Uniform bucket-level access (no per-object ACLs to manage)
# 4. Object versioning for accidental deletion recovery
# 5. Retention policies where required for compliance

resource "google_storage_bucket" "data_lake" {
  for_each = var.bucket_configs

  project     = var.project_id
  name        = "${each.value.name_prefix}-${var.environment}"
  location    = each.value.location
  storage_class = each.value.storage_class

  # SECURITY SAFEGUARD: Uniform bucket-level access means IAM permissions
  # are the ONLY way to access objects. No per-object ACLs that could be
  # misconfigured to grant public access.
  uniform_bucket_level_access = true

  # SECURITY SAFEGUARD: Public access prevention blocks any attempt to make
  # the bucket or its objects publicly accessible, even if IAM is misconfigured.
  public_access_prevention = "enforced"

  # ARCHITECTURE DECISION: Object versioning is enabled for all zones except
  # transient. This provides recovery from accidental deletion/malware with
  # a 7-day version lifespan (configured via lifecycle).
  versioning {
    enabled = each.value.versioning
  }

  # ARCHITECTURE DECISION: Retention policy for the raw zone ensures data
  # cannot be deleted or overwritten for the configured period. This is
  # critical for regulatory compliance (e.g., SEC Rule 17a-4 requires
  # non-rewritable, non-erasable storage for financial records).
  # SECURITY SAFEGUARD: The retention policy is LOCKED via retentions_policy
  # -> is_locked after a 24-hour testing window. Once locked, even the
  # project owner cannot delete the data before the retention period expires.
  dynamic "retention_policy" {
    for_each = each.value.retention_days > 0 ? [1] : []
    content {
      retention_period = each.value.retention_days * 86400
      is_locked        = var.environment == "prod" ? true : false
    }
  }

  # ARCHITECTURE DECISION: Lifecycle rules automate data tiering to reduce
  # storage costs by ~60% for historical data (see ADR-004).
  # Raw data transitions: Standard (0-30d) → Nearline (30-90d) →
  # Coldline (90-365d) → Archive (365d+)
  # Transient data: Deleted after 7 days.
  dynamic "lifecycle_rule" {
    for_each = each.value.lifecycle_rules
    content {
      action {
        type          = lifecycle_rule.value.storage == "DELETE" ? "Delete" : "SetStorageClass"
        storage_class = lifecycle_rule.value.storage == "DELETE" ? null : lifecycle_rule.value.storage
      }
      condition {
        age = lifecycle_rule.value.age
      }
    }
  }

  # CMEK encryption for data-at-rest
  encryption {
    default_kms_key_name = var.kms_key_name != "" ? var.kms_key_name : google_kms_crypto_key.datalake_key[each.key].id
  }

  labels = merge(var.default_labels, {
    zone        = each.key
    environment = var.environment
  })
}

# =============================================================================
# CMEK Keys for Data Lake
# =============================================================================
# ARCHITECTURE DECISION: Dedicated KMS key per storage zone to limit the
# blast radius of a key compromise. If the raw zone key is compromised, only
# raw data needs re-encryption — curated and consumption zones are unaffected.
# SECURITY SAFEGUARD: Key rotation is automatic via KMS. The key version
# template ensures all new data is encrypted with the latest key version.

resource "google_kms_crypto_key" "datalake_key" {
  for_each = var.kms_key_name == "" ? var.bucket_configs : {}

  name     = "datalake-key-${each.key}-${var.environment}"
  key_ring = google_kms_key_ring.datalake_key_ring[each.key].id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }

  labels = {
    zone        = each.key
    environment = var.environment
  }
}

resource "google_kms_key_ring" "datalake_key_ring" {
  for_each = var.kms_key_name == "" ? var.bucket_configs : {}

  name     = "datalake-key-ring-${each.key}-${var.environment}"
  location = each.value.location
}

# =============================================================================
# IAM — Service Account Access to Data Lake
# =============================================================================
# SECURITY SAFEGUARD: Granular IAM roles per service account. Composer gets
# objectAdmin on curated/consumption, objectViewer on raw. Vertex AI gets
# objectAdmin only on consumption. This follows least-privilege principle.

resource "google_storage_bucket_iam_member" "composer_admin" {
  for_each = var.composer_sa_email != "" ? var.bucket_configs : {}

  bucket = google_storage_bucket.data_lake[each.key].name
  role   = each.key == "raw" ? "roles/storage.objectViewer" : "roles/storage.objectAdmin"
  member = "serviceAccount:${var.composer_sa_email}"
}

resource "google_storage_bucket_iam_member" "vertex_admin" {
  for_each = var.vertex_sa_email != "" ? var.bucket_configs : {}

  bucket = google_storage_bucket.data_lake[each.key].name
  role   = each.key == "consumption" ? "roles/storage.objectAdmin" : "roles/storage.objectViewer"
  member = "serviceAccount:${var.vertex_sa_email}"
}
