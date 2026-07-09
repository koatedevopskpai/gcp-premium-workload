# Runbook: BigQuery Dataset Restore

**Target**: RTO 4 hours, RPO 1 hour
**Severity**: P1 (data loss) / P2 (data corruption)
**Owner**: Platform Engineering

## Symptoms

- Users report missing data in BigQuery tables
- Data quality checks fail with unexpected NULL ratios
- Fraud model accuracy drops suddenly (data drift caused by corrupted dataset)
- Accidental table deletion or DROP query executed

## Prerequisites

- Access to BigQuery (roles/bigquery.admin)
- Access to Cloud Console or gcloud CLI
- Access to KMS key for encrypted datasets
- Time machine (snapshot) access enabled on the dataset

## Recovery Options

### Option 1: Time-based Snapshot Recovery (Fastest — RTO < 30 min)

BigQuery automatically retains table snapshots for 7 days (default). Use `FOR SYSTEM_TIME AS OF` to recover.

```sql
-- 1. Create a new table from snapshot (7 days ago max)
CREATE TABLE `project.dataset.restored_table` AS
SELECT *
FROM `project.dataset.original_table`
  FOR SYSTEM_TIME AS OF TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE);

-- 2. Verify row count
SELECT COUNT(*) FROM `project.dataset.restored_table`;

-- 3. Replace the corrupted table
DROP TABLE `project.dataset.original_table`;
ALTER TABLE `project.dataset.restored_table`
  RENAME TO `original_table`;
```

**If you need the exact table schema (including partitioning, clustering, and policy tags):**

```sql
-- 1. Clone the snapshot to preserve schema
CREATE TABLE `project.dataset.restored_table`
  CLONE `project.dataset.original_table`
    FOR SYSTEM_TIME AS OF TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE);

-- 2. Replace corrupted table
DROP TABLE `project.dataset.original_table`;
ALTER TABLE `project.dataset.restored_table`
  RENAME TO `original_table`;
```

### Option 2: Table Snapshot Recovery (RTO < 1 hour)

If table snapshots were explicitly created:

```sql
-- List snapshots
SELECT table_name, snapshot_time_ms
FROM `project.dataset.INFORMATION_SCHEMA.TABLE_SNAPSHOTS`
WHERE table_name = 'original_table';

-- Restore from snapshot
CREATE TABLE `project.dataset.restored_table`
  CLONE `project.dataset.original_table`
    FOR SYSTEM_TIME AS OF TIMESTAMP_MILLIS(<snapshot_time_ms>);
```

### Option 3: Storage Transfer from Curated Zone (RTO < 4 hours)

If BigQuery snapshots have expired (data deleted >7 days ago):

```
# 1. Find the latest Parquet/AVRO export in the curated zone
gsutil ls gs://secondwave-curated-{env}/transaction_features/backups/

# 2. Load into a new table
bq load \
  --source_format=PARQUET \
  --project_id={project_id} \
  {dataset}.restored_table \
  "gs://secondwave-curated-{env}/transaction_features/backups/{date}/*.parquet"

# 3. Verify and rename
bq query --project_id={project_id} "SELECT COUNT(*) FROM {dataset}.restored_table"
bq cp -a {dataset}.original_table {dataset}.original_table.corrupted_backup
bq cp -a {dataset}.restored_table {dataset}.original_table
```

### Option 4: Cross-Region Dataset Copy (DR scenario)

If the entire dataset is lost (not just a table):

```
# 1. In the DR project, verify the replicated dataset
bq show --project_id={dr_project} {dataset}

# 2. Export from DR project
bq extract \
  --project_id={dr_project} \
  --destination_format=PARQUET \
  {dataset}.original_table \
  "gs://secondwave-curated-{env}/dr-restore/{timestamp}/*.parquet"

# 3. Import to primary project
bq load \
  --project_id={project_id} \
  --source_format=PARQUET \
  {dataset}.original_table \
  "gs://secondwave-curated-{env}/dr-restore/{timestamp}/*.parquet"
```

## Verification

After recovery:

1. **Row count check**: Compare row count in restored table vs. pre-incident monitoring metric
2. **Data quality check**: Run the standard quality DAG (`dq_checks_dag`) on the restored table
3. **PII verification**: Run DLP inspection on the restored table to ensure no new PII exposure
4. **Model accuracy**: Run inference on a held-out test set to verify model accuracy > 95% of baseline

## Post-Mortem Data Collection

For root cause analysis, collect before cleanup:

```bash
# 1. Capture table metadata before ANY recovery actions
bq show --format=prettyjson {dataset}.original_table > /tmp/table_metadata_pre_incident.json

# 2. Check audit logs
gcloud logging read \
  "resource.type=bigquery_resource AND protoPayload.methodName=jobservice.query" \
  --limit=100 \
  --project={project_id} > /tmp/bq_audit_logs.json

# 3. Check if a specific query caused the issue
grep -r "DROP TABLE\|DELETE\|UPDATE\|INSERT" /tmp/bq_audit_logs.json
```

## Escalation

If RTO > 4 hours is expected:
1. Escalate to Platform Engineering Lead
2. Notify data engineering team (data consumers affected)
3. Notify fraud detection team (models may need retraining on partial data)
4. File a post-mortem within 24 hours

## Prevention

- Enable `max_time_travel_hours` = 168 on all production datasets
- Create daily table snapshots for all production tables
- Run scheduled backups to the curated zone every 6 hours
- Restore drill executed quarterly — last: 2026-04-01, next: 2026-07-01
