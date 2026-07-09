# Runbook: Composer DAG Failure Diagnostics and Recovery

**Severity**: P2 (single DAG failure) / P1 (all DAGs failing)
**Owner**: Data Engineering (DAG logic) / Platform Engineering (Composer infra)

## Symptoms

- Cloud Monitoring alert: "Composer DAG Failure Rate > 5%"
- Airflow UI shows failed/skipped tasks
- Data pipeline downstream consumers reporting stale data
- Slack #data-pipeline channel showing DAG failure notifications

## Diagnosis

### Step 1: Identify the failing DAG(s)

Check the Cloud Monitoring dashboard or Airflow UI:

```
# Via Airflow CLI (run on Composer pod or via gcloud)
gcloud composer environments run {environment} \
  --location=europe-west2 \
  dags list -- --output=table --sort=-dag_id

# Check recent failures
gcloud composer environments run {environment} \
  --location=europe-west2 \
  tasks list-failed -- --dag_id={dag_id} --execution_date={date}
```

### Step 2: Check Airflow Logs

```
# Composer logs are in Cloud Logging
gcloud logging read \
  "resource.type=cloud_composer_environment AND
   resource.labels.environment_name=secondwave-composer-{env} AND
   severity>=ERROR" \
  --limit=50 \
  --project={project_id}
```

### Step 3: Common Failure Patterns

#### Pattern A: Task Timeout

**Symptom**: Task stuck in "running" state for > task timeout
**Causes**:
- BigQuery query taking too long (increase slot capacity or optimize query)
- Vertex AI training job stuck (check job status in Vertex AI console)
- External API dependency down

**Fix**:
```python
# In the DAG, increase the execution_timeout
from datetime import timedelta

task = BigQueryOperator(
    task_id="long_running_query",
    sql="...",
    use_legacy_sql=False,
    execution_timeout=timedelta(hours=2),  # Was 30 min
    dag=dag,
)
```

#### Pattern B: Out of Memory (OOM)

**Symptom**: Worker pods restarting, tasks show "Killed" in logs
**Causes**:
- Too many concurrent DAG runs for the worker size
- Single task processing too much data

**Fix**:
```bash
# Scale workers via Composer config
gcloud composer environments update {environment} \
  --location=europe-west2 \
  --update-workloads-config=worker-count=5
```

Or optimize the DAG to process data in smaller batches.

#### Pattern C: Permission Error

**Symptom**: Task fails with 403/401 errors
**Causes**:
- Composer SA missing a permission on a new resource
- VPC-SC blocking a new service endpoint
- KMS key access revoked

**Fix**:
```bash
# Grant missing permissions
gcloud projects add-iam-policy-binding {project_id} \
  --member="serviceAccount:{composer_sa}" \
  --role="roles/bigquery.dataEditor"
```

#### Pattern D: DAG Parse Error

**Symptom**: DAG not appearing in Airflow UI
**Causes**:
- Syntax error in DAG file
- Missing Python dependency
- Airflow version incompatibility

**Fix**:
```bash
# Check parse errors
gcloud composer environments run {environment} \
  --location=europe-west2 \
  dags list-runs -- --dag_id={dag_id}

# Update requirements.txt in the DAGs folder
# Add missing package and trigger DAG sync
```

### Step 4: Check Composer Infrastructure Health

```
# Check worker health
gcloud composer environments describe {environment} \
  --location=europe-west2 \
  --format="value(config.workloadsConfig)"

# Check database (Cloud SQL) CPU/memory
gcloud logging read \
  "resource.type=cloudsql_database AND
   resource.labels.database_id={project_id}:{region}-{env}-sql" \
  --limit=20 \
  --project={project_id}
```

## Recovery

### Single DAG Failure

1. **Clear the failed task** in Airflow UI: Browse → Task Instances → Clear
2. **If clearing doesn't work**, set the task to "success" (use with caution):
   ```bash
   gcloud composer environments run {environment} \
     --location=europe-west2 \
     tasks clear -- --dag_id={dag_id} --task_regex={task_id} --start_date={date} --end_date={date}
   ```
3. **If the issue is code-related**, deploy a fix via GCS and unpause the DAG

### All DAGs Failing

1. **Check scheduler health**:
   ```
   gcloud composer environments describe {environment} \
     --location=europe-west2 \
     --format="value(state)"
   ```
   Expected: `RUNNING`

2. **Restart the environment** (last resort, ~15 min downtime):
   ```
   gcloud composer environments restart {environment} \
     --location=europe-west2
   ```

3. **If restart fails**, restore from backup (see DR runbook):
   - Cloud SQL is backed up daily with 7-day retention
   - Composer environment can be recreated from Terraform
   - DAGs are in GCS (versioned) — restore from previous version

### Data Pipeline Catch-Up

After recovery, backfill missed data:

```python
# Trigger a backfill DAG run for the missed period
from datetime import datetime, timedelta

start_date = datetime(2026, 6, 30)  # Date of failure
end_date = datetime(2026, 7, 1)     # Current date

backfill = BackfillDagRunOperator(
    task_id="backfill_missed_data",
    dag_id="fraud_feature_pipeline",
    start_date=start_date,
    end_date=end_date,
    dag=dag,
)
```

## Prevention

- **Retry policies**: All DAG tasks should have retries (default: 3, with exponential backoff)
- **SLAs**: Set SLA timestamps on critical tasks to get early warnings
- **Testing**: Run DAGs in the dev environment before deploying to prod
- **Monitoring**: Alert on DAG failure rate > 5% over 5 minutes (configured in `main.tf`)
- **Capacity planning**: Review worker utilization weekly during the platform review

## Related

- Main runbook: `docs/runbooks/data-pipeline-dr.md`
- Terraform: `modules/composer/main.tf`
- ADR-001: Composer over Self-Hosted Airflow
