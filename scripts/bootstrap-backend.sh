#!/usr/bin/env bash
# =============================================================================
# Bootstrap Terraform Backend — GCS State Bucket + KMS Key
# =============================================================================
# This script creates the GCS bucket and KMS key needed for Terraform remote
# state storage. Run this once per project before running 'terraform init'.
#
# Usage:
#   ./scripts/bootstrap-backend.sh <PROJECT_ID> [REGION]
#
# Example:
#   ./scripts/bootstrap-backend.sh secondwave-dev europe-west2
#
# ARCHITECTURE DECISION: Separating state infrastructure from application
# infrastructure prevents accidental state deletion. The state bucket and KMS
# key are created outside Terraform to avoid the chicken-and-egg problem of
# needing state to store state.
#
# SECURITY SAFEGUARD: The state bucket has:
# 1. Object versioning (recover from accidental state deletion)
# 2. CMEK encryption (state may contain plaintext resource values)
# 3. Public access prevention
# 4. Uniform bucket-level access

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <PROJECT_ID> [REGION]}"
REGION="${2:-europe-west2}"
BUCKET_NAME="${PROJECT_ID}-tfstate"

echo "=== Bootstrapping Terraform Backend for ${PROJECT_ID} ==="

# Enable required APIs
echo ">>> Enabling required APIs..."
gcloud services enable \
  cloudkms.googleapis.com \
  storage.googleapis.com \
  storage-component.googleapis.com \
  --project="${PROJECT_ID}"

# Create KMS key ring and key for state encryption
echo ">>> Creating KMS key for state encryption..."
if ! gcloud kms keyrings describe "tf-state" \
  --project="${PROJECT_ID}" \
  --location="global" &>/dev/null; then
  gcloud kms keyrings create "tf-state" \
    --project="${PROJECT_ID}" \
    --location="global"
  echo "  Keyring 'tf-state' created"
else
  echo "  Keyring 'tf-state' already exists"
fi

if ! gcloud kms keys describe "tf-state-key" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --keyring="tf-state" &>/dev/null; then
  gcloud kms keys create "tf-state-key" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --keyring="tf-state" \
    --purpose="encryption-decrypt"
  echo "  Key 'tf-state-key' created"
else
  echo "  Key 'tf-state-key' already exists"
fi

# Get the KMS key resource ID
KMS_KEY_ID=$(gcloud kms keys describe "tf-state-key" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --keyring="tf-state" \
  --format="value(name)")

echo "  KMS Key ID: ${KMS_KEY_ID}"

# Create the GCS state bucket
echo ">>> Creating GCS state bucket..."
if ! gsutil ls -p "${PROJECT_ID}" "gs://${BUCKET_NAME}" &>/dev/null 2>&1; then
  gsutil mb -p "${PROJECT_ID}" \
    -l "${REGION}" \
    -b "on" \
    "gs://${BUCKET_NAME}"
  echo "  Bucket '${BUCKET_NAME}' created"
else
  echo "  Bucket '${BUCKET_NAME}' already exists"
fi

# Configure bucket settings
echo ">>> Configuring bucket settings..."

# Enable versioning — critical for recovering from accidental state deletion
gsutil versioning set on "gs://${BUCKET_NAME}"
echo "  Versioning: enabled"

# Set uniform bucket-level access (no per-object ACLs)
gsutil uniformbucketlevelaccess set on "gs://${BUCKET_NAME}"
echo "  Uniform bucket-level access: enabled"

# Configure CMEK on the bucket
gsutil kms authorize \
  -p "${PROJECT_ID}" \
  -k "${KMS_KEY_ID}" \
  "gs://${BUCKET_NAME}"
gsutil kms encryption \
  -k "${KMS_KEY_ID}" \
  "gs://${BUCKET_NAME}"
echo "  CMEK encryption: enabled"

# Public access prevention
gsutil pap set enforced "gs://${BUCKET_NAME}"
echo "  Public access prevention: enforced"

# Set lifecycle policy to auto-delete old state versions after 365 days
cat > /tmp/tfstate-lifecycle.json << 'LIFECYCLE_EOF'
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "age": 365,
          "isLive": false
        }
      }
    ]
  }
}
LIFECYCLE_EOF
gsutil lifecycle set /tmp/tfstate-lifecycle.json "gs://${BUCKET_NAME}"
echo "  Lifecycle: non-current versions deleted after 365 days"

# Grant the Terraform service account access to the bucket and key
echo ">>> Granting access to Terraform service account..."
TERRAFORM_SA="terraform-sa@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "${TERRAFORM_SA}" &>/dev/null 2>&1; then
  gsutil iam ch \
    "serviceAccount:${TERRAFORM_SA}:roles/storage.objectAdmin" \
    "gs://${BUCKET_NAME}"

  gcloud kms keys add-iam-policy-binding "tf-state-key" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --keyring="tf-state" \
    --member="serviceAccount:${TERRAFORM_SA}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

  echo "  Access granted to ${TERRAFORM_SA}"
else
  echo "  WARNING: Terraform SA ${TERRAFORM_SA} not found. Create it with:"
  echo "    gcloud iam service-accounts create terraform-sa --project=${PROJECT_ID}"
  echo "    gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
  echo "      --member='serviceAccount:${TERRAFORM_SA}' \\"
  echo "      --role='roles/editor'"
fi

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Backend configuration for versions.tf:"
echo ""
echo "backend \"gcs\" {"
echo "  bucket         = \"${BUCKET_NAME}\""
echo "  prefix         = \"terraform/state/premium-workload\""
echo "  kms_encryption_key = \"${KMS_KEY_ID}\""
echo "}"
echo ""
echo "KMS Key ID: ${KMS_KEY_ID}"
