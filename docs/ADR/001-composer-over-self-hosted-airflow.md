# ADR-001: Cloud Composer over Self-Hosted Airflow on GKE

## Status

Accepted

## Context

SecondWave needs a workflow orchestration platform for the fraud detection ML pipeline. The platform team of 5 engineers must manage:
- 50+ DAGs for data ingestion, transformation, model training, and inference
- 5,000+ DAG runs per day across dev/staging/prod
- Integration with BigQuery, Vertex AI, Cloud Storage, and DLP
- GDPR compliance with audit logging on all pipeline executions
- VPC-SC perimeter enforcement

The two primary options are:
1. **Cloud Composer** (managed Airflow by Google)
2. **Self-hosted Airflow on GKE**

## Decision

We choose **Cloud Composer 2** for all environments.

## Rationale

| Factor | Cloud Composer | Self-hosted Airflow on GKE |
|---|---|---|
| **Setup time** | ~30 minutes (Terraform) | ~2 weeks (cluster, storage, networking, HA, monitoring) |
| **Infra maintenance** | None (Google manages PostgreSQL, Redis, web server, scheduler, workers) | Full team responsibility — PgSQL upgrades, Redis failures, worker OOM, scheduler lag |
| **Scaling** | Auto-scales workers based on Celery queue depth | Requires HPA configuration, custom metrics, and vertical pod autoscaling tuning |
| **Security** | Native VPC-SC, CMEK, Cloud Audit Logs, IAM integration | Manual integration for all of the above |
| **Observability** | Built-in Cloud Monitoring dashboards for DAGs, tasks, queue depth, worker health | Requires custom Prometheus exporters, Grafana dashboards, and alert rules |
| **Upgrades** | Google-managed with configurable maintenance windows | Manual Airflow version upgrades (schema migrations, backward compatibility testing) |
| **Cost (5k runs/day)** | ~$800/month | ~$300/month (compute) + ~$50/month (CloudSQL) + engineer time |

### Cost-Benefit Analysis

The $500/month premium for Composer is offset by:

- **Engineer time**: At £600/day contractor rate, even 1 day/month of Airflow maintenance costs £600. Composer eliminates this entirely.
- **Velocity**: Composer's one-click DAG deployment (GCS sync) vs. building a CI/CD pipeline for custom Airflow images saves ~2 days/sprint.
- **Risk reduction**: Google's SLA covers Airflow infrastructure. With self-hosted, a PostgreSQL failure at 2 AM costs £1,200+ in out-of-hours support.

## Consequences

1. **Positive**: Team freed to focus on ML pipeline logic, not Airflow infrastructure
2. **Positive**: Audit-ready from day one — Composer logs all API calls, DAG runs, and task instances to Cloud Audit Logs
3. **Positive**: One Terraform resource vs. 20+ Kubernetes manifests
4. **Negative**: Vendor lock-in — migrating to self-hosted later would require DAG refactoring
5. **Negative**: Limited Airflow config customization (e.g., custom executors, Python packages are constrained)
6. **Negative**: Higher per-DAG-run cost at scale (but break-even is ~50k runs/day — well above our current volume)

## Mitigation

To address vendor lock-in:
- All DAGs use standard Airflow operators (no Composer-specific APIs)
- GCS DAG bucket is abstracted via an environment variable
- Custom Python packages are managed via `requirements.txt` (Composer-native)

If we outgrow Composer, migration to self-hosted Airflow requires:
1. Export DAGs from GCS
2. Export Airflow variables and connections
3. Point to same PostgreSQL (or dump/restore)
4. Set up the same worker image

## Related

- ADR-004: Data Lake Lifecycle for Cost
- Technical: `modules/composer/main.tf`
