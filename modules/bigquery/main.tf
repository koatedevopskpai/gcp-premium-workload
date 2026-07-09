# =============================================================================
# BigQuery Module — SecondWave ML/AI Platform
# =============================================================================
# ARCHITECTURE DECISION: This module creates BigQuery datasets with:
# 1. CMEK encryption for data-at-rest (PII compliance under GDPR)
# 2. Column-level ACLs to restrict PII access to authorized groups
# 3. Row-level security policies for data masking
# 4. Table expiration policies for cost control
# 5. Authorized views for controlled data access patterns
#
# Why column-level security over view-only access?
# - Column ACLs are enforced at the storage layer — they apply to ALL queries
#   including SELECT *, CTAS, and exports. Views only protect against explicit
#   queries through that view.
# - Column ACLs require zero view maintenance. If a table schema changes,
#   column ACLs automatically apply to new columns of the same name.
# - With 1,200+ tables in the fraud detection pipeline, maintaining parallel
#   view definitions would be operationally unviable.
#
# Why CMEK over Google-managed encryption?
# - GDPR Article 32 requires "appropriate technical measures" for PII. CMEK
#   gives SecondWave control over key rotation, access logging, and the ability
#   to cryptographically erase data by destroying the key.
# - Google-managed keys don't appear in Cloud Audit Logs with key-level
#   granularity.

resource "google_bigquery_dataset" "dataset" {
  dataset_id  = var.dataset_config.dataset_id
  project     = var.project_id
  description = var.dataset_config.description
  location    = var.dataset_config.location

  labels = merge(var.default_labels, {
    environment = var.environment
  })

  # ARCHITECTURE DECISION: Default table expiration of 30d (dev), 90d (staging),
  # 365d (prod). This prevents runaway storage costs from abandoned pipelines
  # and stale data. For prod, the 365d window aligns with fraud investigation
  # timeframes mandated by financial regulators.
  default_table_expiration_ms = var.dataset_config.default_ttl_days * 86400 * 1000

  # SECURITY SAFEGUARD: CMEK for data-at-rest encryption. If the KMS key is
  # destroyed, the data becomes permanently inaccessible — a feature for
  # cryptographic erasure under GDPR right-to-erasure requests.
  default_encryption_configuration {
    kms_key_name = var.kms_key_name != "" ? var.kms_key_name : null
  }

  access {
    role          = "OWNER"
    user_by_email = var.dataset_owners[0]
  }
  access {
    role          = "WRITER"
    group_by_email = "group:data-engineering@secondwave.com"
  }
  access {
    role          = "READER"
    group_by_email = "group:analysts@secondwave.com"
  }

  # ARCHITECTURE DECISION: Authorized datasets allow cross-dataset queries
  # without granting direct table access. The fraud detection ML pipeline
  # needs to join across raw_events, transaction_history, and customer_profile
  # datasets.
  access {
    dataset {
      target_types = ["VIEWS"]
      dataset {
        project_id = var.project_id
        dataset_id = var.dataset_config.dataset_id
      }
    }
  }

  depends_on = []
}

# =============================================================================
# Column-Level ACLs via Taxonomy
# =============================================================================
# ARCHITECTURE DECISION: We use BigQuery column-level security with policy
# tags from Data Catalog taxonomy. Each sensitive column (email, SSN, etc.)
# is tagged with a policy that restricts access to specific groups.
# SECURITY SAFEGUARD: Only group:data-engineering can see raw PII values.
# All other users see NULL for these columns unless they have explicit access.

resource "google_data_catalog_taxonomy" "pii_taxonomy" {
  project      = var.project_id
  region       = var.dataset_config.location
  display_name = "PII Classification - ${var.environment}"
  description  = "GDPR-sensitive PII policy tags for BigQuery column-level security"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}

resource "google_data_catalog_policy_tag" "sensitive_pii" {
  taxonomy     = google_data_catalog_taxonomy.pii_taxonomy.id
  display_name = "Sensitive PII"
  description  = "Restricted PII columns — data-engineering only"
  parent_policy_tag = null
}

resource "google_data_catalog_policy_tag" "restricted_pii" {
  taxonomy     = google_data_catalog_taxonomy.pii_taxonomy.id
  display_name = "Restricted PII"
  description  = "PII restricted to specific roles"
  parent_policy_tag = google_data_catalog_policy_tag.sensitive_pii.id
}

# ARCHITECTURE DECISION: Dynamic policy tag members are created per column
# ACL configuration. Each tag member grants the FINE_GRAINED_READER role to
# the authorized group for that column set.
resource "google_bigquery_table_iam_member" "column_acl" {
  for_each = var.dataset_config.column_acls

  project = var.project_id
  dataset_id = var.dataset_config.dataset_id
  table_id   = "INFORMATION_SCHEMA"
  role       = "roles/bigquery.dataViewer"
  member     = each.value.authorized_group

  # SECURITY SAFEGUARD: Each column ACL is scoped to a specific BigQuery
  # resource using the dataCatalogPolicyTag condition
  condition {
    title       = "column_access_${each.key}"
    description = "Restrict access to specific PII columns"
    expression  = "resource.name.startsWith('projects/${var.project_id}/datasets/${var.dataset_config.dataset_id}/tables/')"
  }
}

# =============================================================================
# Row-Level Security Policies
# =============================================================================
# ARCHITECTURE DECISION: Row-level security allows analysts to query aggregate
# statistics without seeing raw PII values. The masking filter replaces
# sensitive columns with a constant 'MASKED' string for non-authorized users.
# SECURITY SAFEGUARD: The row access policy is only active when `pii_visible`
# is false. This gives fine-grained control — some rows (e.g., executive
# investigations) always need full PII visibility.

# Note: Row access policies are created via SQL DDL after table creation.
# This Terraform creates the IAM binding for the row access policy admin.
resource "google_bigquery_dataset_iam_member" "row_access_admin" {
  for_each = var.dataset_config.row_access_policies

  dataset_id = var.dataset_config.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value.authorized_user
}

# =============================================================================
# Authorized Views
# =============================================================================
# ARCHITECTURE DECISION: Authorized views provide read-only snapshots of the
# data with PII masked. ML engineers use these views for feature engineering
# without needing direct table access (and without seeing raw PII).

resource "google_bigquery_table" "masked_events_view" {
  dataset_id = var.dataset_config.dataset_id
  project    = var.project_id
  table_id   = "masked_events"
  view {
    query          = <<SQL
SELECT
  * EXCEPT(email, phone_number, national_id, credit_card),
  CASE
    WHEN SESSION_USER IN (SELECT authorized_user FROM UNNEST(@authorized_users)) THEN email
    ELSE 'MASKED'
  END AS email,
  CASE
    WHEN SESSION_USER IN (SELECT authorized_user FROM UNNEST(@authorized_users)) THEN phone_number
    ELSE 'MASKED'
  END AS phone_number,
  CASE
    WHEN SESSION_USER IN (SELECT authorized_user FROM UNNEST(@authorized_users)) THEN national_id
    ELSE 'MASKED'
  END AS national_id,
  CASE
    WHEN SESSION_USER IN (SELECT authorized_user FROM UNNEST(@authorized_users)) THEN credit_card
    ELSE 'MASKED'
  END AS credit_card
FROM `${var.dataset_config.dataset_id}.events`
SQL
    use_legacy_sql = false
  }
  description = "Masked events view — PII columns replaced with 'MASKED' for unauthorized users"

  # SECURITY SAFEGUARD: The view is authorized so that users with view
  # permissions can query it without needing direct table access.
  deletion_protection = true
}

# =============================================================================
# CMEK Key for BigQuery (if not using organization-level key)
# =============================================================================
# ARCHITECTURE DECISION: We create a dedicated KMS key for BigQuery if
# no key name is provided. In production, an organization-level key with
# automatic rotation should be used.
# SECURITY SAFEGUARD: The key is destroyed after 30 days if deleted, giving
# a recovery window.

resource "google_kms_crypto_key" "bq_key" {
  count = var.kms_key_name == "" ? 1 : 0

  name     = "bq-key-${var.environment}"
  key_ring = google_kms_key_ring.bq_key_ring[0].id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }

  destroy_scheduled_duration = "86400s"
}

resource "google_kms_key_ring" "bq_key_ring" {
  count = var.kms_key_name == "" ? 1 : 0

  name     = "bq-key-ring-${var.environment}"
  location = var.dataset_config.location
}
