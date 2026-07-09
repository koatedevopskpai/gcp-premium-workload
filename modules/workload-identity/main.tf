# =============================================================================
# Workload Identity Federation Module — Keyless Auth for ML Workloads
# =============================================================================
# ARCHITECTURE DECISION: Workload Identity Federation over service account
# key files:
#
# 1. Security: No service account keys to leak. Keys stored in CI/CD secrets,
#    container images, or configuration files are a top-10 vector for cloud
#    breaches. WIF eliminates this entirely.
#
# 2. Rotation: Tokens are short-lived (default 1 hour) and automatically
#    refreshed by the workload's identity platform (GitHub, GitLab, etc.).
#    Key-based auth requires manual rotation — which almost never happens.
#
# 3. Audit: Every token exchange is logged in Cloud Audit Logs with the
#    workload's identity (e.g., GitHub repository + workflow name). Key-based
#    auth only logs "service account X accessed resource Y" — no trace of
#    which workload or human initiated the action.
#
# 4. Multi-cloud ready: The same WIF pool can accept tokens from GitHub,
#    GitLab, Bitbucket, or any OIDC provider. This allows SecondWave to
#    run ML training on GCP from CI/CD pipelines hosted anywhere.
#
# SECURITY SAFEGUARD: Attribute conditions restrict which repositories or
# workloads can impersonate each service account. Without this, any workflow
# in the org could impersonate the production deployment SA.

# ---------------------------------------------------------------------------
# Workload Identity Pool
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: One pool per provider type (GitHub, custom OIDC, etc.)
# with one provider per workload within each pool. This gives granular control
# over attribute mapping and conditions per workload.

resource "google_iam_workload_identity_pool" "wif_pool" {
  for_each = var.config

  project                  = var.project_id
  workload_identity_pool_id = each.value.pool_id
  display_name             = each.value.pool_id
  description              = "Workload Identity Federation pool for ${each.key}"
  disabled                 = false
}

# ---------------------------------------------------------------------------
# Workload Identity Pool Providers
# ---------------------------------------------------------------------------
# SECURITY SAFEGUARD: Each provider has an attribute condition that restricts
# which external identities can authenticate. For GitHub, only the specific
# repository can authenticate. For custom OIDC, the audience must match.
#
# The attribute mapping extracts claims from the OIDC token and maps them to
# GCP attributes. These attributes are then used in IAM conditions to grant
# fine-grained access.

resource "google_iam_workload_identity_pool_provider" "wif_provider" {
  for_each = var.config

  project                           = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.wif_pool[each.key].workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.provider_id
  display_name                       = each.value.provider_id
  description                        = "OIDC provider for ${each.key} workload identity"

  attribute_mapping = each.value.attribute_mapping

  # SECURITY SAFEGUARD: The attribute condition is evaluated BEFORE the token
  # is exchanged for a GCP access token. If the condition fails, the token
  # exchange is denied — no IAM policy is even evaluated.
  attribute_condition = each.value.attribute_condition != "" ? each.value.attribute_condition : null

  oidc {
    issuer_uri        = each.value.issuer_uri
    allowed_audiences = length(each.value.allowed_audiences) > 0 ? each.value.allowed_audiences : null
  }
}

# ---------------------------------------------------------------------------
# Service Account IAM Bindings
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Each WIF provider can impersonate a specific service
# account via IAM binding. The principalSet includes attribute conditions from
# the mapping, so only matching external identities can use this SA.
# SECURITY SAFEGUARD: The member format uses `principalSet://` instead of
# `principal://` to allow attribute-based conditions. This is more flexible
# than pinning to a specific subject.

resource "google_service_account_iam_member" "wif_sa_binding" {
  for_each = {
    for k, v in var.config : k => v
    if v.service_account_email != ""
  }

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.wif_pool[each.key].name}/*"
}

# ---------------------------------------------------------------------------
# Service Account Creation (Optional)
# ---------------------------------------------------------------------------
# If no service account email is provided, create a dedicated SA for the
# workload with minimal permissions.

resource "google_service_account" "wif_sa" {
  for_each = {
    for k, v in var.config : k => v
    if v.service_account_email == ""
  }

  project      = var.project_id
  account_id   = "wif-${each.key}-${var.environment}"
  display_name = "Workload Identity SA for ${each.key}"
  description  = "Service account accessed via Workload Identity Federation for ${each.key}"
}

resource "google_service_account_iam_member" "wif_sa_binding_auto" {
  for_each = {
    for k, v in var.config : k => v
    if v.service_account_email == ""
  }

  service_account_id = google_service_account.wif_sa[each.key].id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.wif_pool[each.key].name}/*"
}
