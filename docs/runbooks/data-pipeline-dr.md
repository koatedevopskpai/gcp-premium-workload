# Runbook: ML/AI Data Platform Disaster Recovery

**Target**: RTO 4 hours, RPO 1 hour
**Severity**: P0 (platform-wide outage)
**Owner**: Platform Engineering Lead

## Scope

This runbook covers recovery of the entire ML/AI platform:

| Component | RTO | RPO | DR Strategy |
|---|---|---|---|
| BigQuery datasets | 4h | 1h | Time travel (7d), daily snapshots, cross-region replication (planned) |
| Cloud Storage data lake | 2h | 0h (multi-region) / 1h (regional) | Object versioning, cross-region mirror (planned) |
| Cloud Composer | 4h | 1h | Terraform re-create, DAGs in GCS (versioned), Cloud SQL backups |
| Vertex AI Workbench | 2h | N/A | Terraform re-create, notebooks in source control |
| Vector Search indexes | 4h | 6h | Index export to GCS weekly, rebuild from embeddings |
| Cloud DLP templates | 1h | N/A | Terraform re-create |
| Workload Identity | 1h | N/A | Terraform re-create |
| VPC-SC perimeter | 1h | N/A | Terraform re-create |

## DR Scenarios

### Scenario 1: Regional Outage (e.g., europe-west2 down)

**Detection**: Cloud Monitoring shows all resources in europe-west2 as UNKNOWN.

**Response**:

1. **Activate DR project**: The `secondwave-dr` project in europe-west1 (Belgium) contains replicated infrastructure.

   ```bash
   export DR_PROJECT="secondwave-dr"
   export PRIMARY_PROJECT="secondwave-prod"
   gcloud config set project ${DR_PROJECT}
   ```

2. **Point Composer to DR DAGs**: Update Composer's DAG GCS prefix to the replicated bucket.

   ```bash
   gcloud composer environments update secondwave-composer-prod \
     --location=europe-west1 \
     --update-env-variables=DAG_BUCKET=gs://secondwave-dags-dr/
   ```

3. **Switch BigQuery queries**: Update data source references in the fraud API.

   ```bash
   # Update the environment variable that the fraud API uses
   gcloud run services update fraud-detection-api \
     --region=europe-west1 \
     --update-env-vars=BQ_DATASET=secondwave_prod_dr
   ```

4. **Verify Vector Search**: Check that the DR Vector Search index is deployed.

   ```bash
   gcloud ai index-endpoints list \
     --region=europe-west1 \
     --project=${DR_PROJECT}
   ```

5. **Update DNS**: Point API gateway to the DR region's Cloud Run services.

   **RTO**: 2 hours (infrastructure) + 2 hours (data verification)

### Scenario 2: Data Corruption (e.g., accidental PII exposure)

**Detection**: DLP alert or data quality check failure.

**Response**:

1. **Isolate affected data**: Immediately revoke IAM access to the affected dataset.

   ```bash
   gcloud projects add-iam-policy-binding ${PRIMARY_PROJECT} \
     --member="group:data-engineering@secondwave.com" \
     --role="roles/bigquery.dataViewer" \
     --condition=None
   ```

2. **Restore from time travel** (see `bigquery-dataset-restore.md`):

   ```sql
   CREATE TABLE `secondwave_prod.events_clean`
   CLONE `secondwave_prod.events`
     FOR SYSTEM_TIME AS OF TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR);
   ```

3. **Run DLP scan** on the restored data to verify no PII.

4. **Re-apply column ACLs** if they were removed.

   **RTO**: 1 hour (restore) + 1 hour (verification)

### Scenario 3: Accidental Terraform State Deletion

**Detection**: `terraform apply` fails with "state not found" or orphaned resources.

**Response**:

1. **Restore state from GCS versioning**:

   ```bash
   # List state versions
   gsutil ls -la gs://secondwave-prod-tfstate/terraform/state/premium-workload/default.tfstate

   # Restore previous version
   gsutil cp gs://secondwave-prod-tfstate/terraform/state/premium-workload/default.tfstate#<generation> \
     gs://secondwave-prod-tfstate/terraform/state/premium-workload/default.tfstate
   ```

2. **If state cannot be restored**, re-import resources:

   ```bash
   # Import all resources into new state
   terraform import module.bigquery.google_bigquery_dataset.dataset \
     projects/${PRIMARY_PROJECT}/datasets/secondwave_prod

   terraform import module.composer.google_composer_environment.composer \
     ${PRIMARY_PROJECT}/europe-west2/secondwave-composer-prod
   # ... repeat for all resources
   ```

   **RTO**: 2 hours if state restored, 4 hours if full re-import needed

## Backup Verification

Monthly DR drill schedule:

| Component | Check | Frequency | Last Verified |
|---|---|---|---|
| BigQuery time travel | Restore a test table | Monthly | 2026-06-15 |
| Data Lake versioning | Recover a deleted object | Monthly | 2026-06-15 |
| Composer DAGs | Sync DAGs to DR project | Monthly | 2026-06-10 |
| Vector Search index | Export and re-deploy | Quarterly | 2026-04-01 |
| Terraform state | Verify state backup | Monthly | 2026-06-20 |

## DR Automation

The DR process is partially automated via the `scripts/dr-failover.sh` script (to be created):

```bash
# Trigger DR failover
./scripts/dr-failover.sh --target=dr --reason=regional-outage

# Trigger DR failback
./scripts/dr-failover.sh --target=primary --reason=region-restored
```

## Communication

| Stakeholder | Channel | Notification |
|---|---|---|
| Platform Engineering | PagerDuty | P0 incident alert |
| Data Engineering | #data-pipeline Slack | Within 5 min |
| Fraud Detection Team | #fraud-alerts Slack | Within 15 min |
| CISO (if PII involved) | Email + Phone | Within 1 hour (GDPR Article 33) |
| All hands | #company Slack | Within 2 hours |

## Post-Mortem

After any DR event:

1. File incident report within 24 hours
2. Run post-mortem meeting within 48 hours
3. Update this runbook with lessons learned
4. Schedule additional DR drill if failure was due to process gap

## Related

- ADR-004: Data Lake Lifecycle for Cost
- Runbook: `docs/runbooks/bigquery-dataset-restore.md`
- Runbook: `docs/runbooks/composer-dag-failure.md`
