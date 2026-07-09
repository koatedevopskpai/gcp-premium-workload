#!/usr/bin/env bash
# =============================================================================
# Seed Data Lake — Initial Folder Structure
# =============================================================================
# Creates the initial directory structure in each data lake zone bucket.
#
# Usage:
#   ./scripts/seed-data-lake.sh <PROJECT_ID> [ENVIRONMENT]
#
# Example:
#   ./scripts/seed-data-lake.sh secondwave-dev dev
#
# ARCHITECTURE DECISION: The folder structure encodes data governance
# information: source system, date partition, and data domain. This makes
# it trivial to apply lifecycle policies and IAM at the folder level via
# gsutil (or via bucket-level IAM with folder prefixes).

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <PROJECT_ID> [ENVIRONMENT]}"
ENVIRONMENT="${2:-dev}"

# Strip suffix if environment is embedded
BUCKET_PREFIX="${PROJECT_ID%-*}"
if [ -z "${BUCKET_PREFIX}" ]; then
  BUCKET_PREFIX="${PROJECT_ID}"
fi
BUCKET_PREFIX="secondwave"

echo "=== Seeding Data Lake — ${PROJECT_ID} / ${ENVIRONMENT} ==="

# Zones: raw, curated, consumption, transient
ZONES=("raw" "curated" "consumption" "transient")

for ZONE in "${ZONES[@]}"; do
  BUCKET="${BUCKET_PREFIX}-${ZONE}-${ENVIRONMENT}"
  echo ""
  echo ">>> Seeding: gs://${BUCKET}"

  # Check bucket exists
  if ! gsutil ls -p "${PROJECT_ID}" "gs://${BUCKET}" &>/dev/null 2>&1; then
    echo "  WARNING: Bucket does not exist. Skipping."
    continue
  fi

  case "${ZONE}" in
    raw)
      # Raw zone: immutable landing for all ingested data
      # Partitioned by source system → date → data domain
      for SOURCE in "transactions" "claims" "customers" "fraud-reports" "external"; do
        # Create a placeholder .keep file so the folder structure is visible
        # even before data lands
        echo "Created $(date -u)" | gsutil cp - \
          "gs://${BUCKET}/${SOURCE}/_STRUCTURE/zone.keep"
        echo "  Created: ${SOURCE}/"
      done
      ;;

    curated)
      # Curated zone: cleaned, deduplicated, enriched data
      # Partitioned by data domain → processing date
      for DOMAIN in "transaction_features" "customer_360" "fraud_labels" "claim_embeddings"; do
        mkdir -p "/tmp/datalake-seed/${DOMAIN}"
        echo "Created $(date -u)" | gsutil cp - \
          "gs://${BUCKET}/${DOMAIN}/_STRUCTURE/zone.keep"
        echo "  Created: ${DOMAIN}/"
      done
      ;;

    consumption)
      # Consumption zone: aggregated, business-ready datasets
      # Partitioned by use case
      for USECASE in "ml-features" "dashboards" "api-endpoints" "reports"; do
        echo "Created $(date -u)" | gsutil cp - \
          "gs://${BUCKET}/${USECASE}/_STRUCTURE/zone.keep"
        echo "  Created: ${USECASE}/"
      done
      ;;

    transient)
      # Transient zone: temporary processing outputs (auto-deletes after 7d)
      for WORKSPACE in "model-training" "data-export" "ad-hoc-queries" "etl-staging"; do
        echo "Created $(date -u)" | gsutil cp - \
          "gs://${BUCKET}/${WORKSPACE}/_STRUCTURE/zone.keep"
        echo "  Created: ${WORKSPACE}/"
      done
      ;;
  esac

  # Create _config folder with zone metadata
  cat > /tmp/zone-metadata.json << METADATA_EOF
{
  "zone": "${ZONE}",
  "environment": "${ENVIRONMENT}",
  "project": "${PROJECT_ID}",
  "created": "$(date -u -Iseconds)",
  "lifecycle": "$(case ${ZONE} in
    raw) echo "standard→nearline(30d)→coldline(90d)→archive(365d)" ;;
    curated) echo "nearline→coldline(90d)" ;;
    consumption) echo "standard" ;;
    transient) echo "delete(7d)" ;;
  esac)",
  "retention_days": "$(case ${ZONE} in
    raw) echo "7" ;;
    *) echo "0" ;;
  esac)",
  "versioning": "$(case ${ZONE} in
    transient) echo "false" ;;
    *) echo "true" ;;
  esac)",
  "encryption": "CMEK",
  "public_access": "blocked"
}
METADATA_EOF
  gsutil cp /tmp/zone-metadata.json "gs://${BUCKET}/_config/zone-metadata.json"
  echo "  Created: _config/zone-metadata.json"

  # Create _logs folder for pipeline audit logs
  echo "Created $(date -u)" | gsutil cp - \
    "gs://${BUCKET}/_logs/_STRUCTURE/zone.keep"
  echo "  Created: _logs/"
done

echo ""
echo "=== Data lake seeding complete ==="
echo ""
echo "Bucket structure created:"
for ZONE in "${ZONES[@]}"; do
  BUCKET="${BUCKET_PREFIX}-${ZONE}-${ENVIRONMENT}"
  echo "  gs://${BUCKET}/"
  echo "    ├── _config/"
  echo "    ├── _logs/"
  case "${ZONE}" in
    raw)        echo "    ├── transactions/ | claims/ | customers/ | fraud-reports/ | external/" ;;
    curated)    echo "    ├── transaction_features/ | customer_360/ | fraud_labels/ | claim_embeddings/" ;;
    consumption) echo "    ├── ml-features/ | dashboards/ | api-endpoints/ | reports/" ;;
    transient)  echo "    ├── model-training/ | data-export/ | ad-hoc-queries/ | etl-staging/" ;;
  esac
done
