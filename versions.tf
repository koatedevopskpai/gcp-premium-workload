# =============================================================================
# Terraform & Provider Version Constraints
# SecondWave ML/AI Platform — Premium Workload
# =============================================================================

# ARCHITECTURE DECISION: Pinning provider versions ensures reproducible builds.
# We pin to a specific minor version range (e.g. ~> 5.0) rather than exact
# patch so that critical security patches are automatically picked up while
# breaking changes are not.
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.38"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ARCHITECTURE DECISION: GCS backend for state locking and remote state.
  # The bucket is bootstrapped by scripts/bootstrap-backend.sh.
  # Uncomment and configure after bootstrapping:
  #
  # backend "gcs" {
  #   bucket         = "<PROJECT_ID>-tfstate"
  #   prefix         = "terraform/state/premium-workload"
  #   kms_encryption_key = "projects/<PROJECT_ID>/locations/global/keyRings/tf-state/cryptoKeys/tf-state-key"
  # }
}

# ARCHITECTURE DECISION: Using both google and google-beta providers.
# Several resources (CMEK for Composer, VPC-SC perimeters, Workbench)
# were GA'd in the beta provider before the stable provider. We use google-beta
# for these resources and google for standard resources.
provider "google" {
  project = var.project_id
  region  = var.region
}

# SECURITY SAFEGUARD: The impersonate_service_account block prevents running
# Terraform under a user's personal credentials. All operations are scoped to
# the Terraform service account's permissions.
# provider "google" {
#   impersonate_service_account = "terraform-sa@${var.project_id}.iam.gserviceaccount.com"
# }

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
