# =============================================================================
# TFLint Configuration — SecondWave ML/AI Platform
# =============================================================================
# ARCHITECTURE DECISION: TFLint catches Terraform-specific issues that
# 'terraform validate' misses: deprecated syntax, provider-specific best
# practices, and unused declarations.

config {
  format = "compact"
  module = true
  force  = false
}

plugin "google" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}

# Google-specific rules
rule "google_bigquery_dataset_default_encryption" {
  enabled = true
}

rule "google_storage_bucket_public_access_prevention" {
  enabled = true
}

rule "google_compute_instance_shielded_vm" {
  enabled = true
}

rule "google_service_account_iam_member_no_conditions" {
  enabled = true
}
