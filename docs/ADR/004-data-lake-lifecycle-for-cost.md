# ADR-004: Data Lake Lifecycle Tiering for Cost Optimization

## Status

Accepted

## Context

SecondWave's data lake stores ~50TB of fraud-related data:
- Raw transaction logs (uncompressed JSON) — ~30TB
- Curated/enriched data (Parquet) — ~10TB
- ML features and embeddings — ~5TB
- Transient processing outputs (deleted after processing) — ~5TB

Projected 12-month growth: 100TB total.

The data has a clear access pattern:
- **<30 days**: Hot — actively queried for model training, fraud investigation, QA
- **30-90 days**: Warm — occasional investigation queries, model re-training
- **90-365 days**: Cool — regulatory hold, annual model validation
- **>365 days**: Cold — regulatory compliance (GDPR Article 5 requires data minimization, but some financial regulations require 7-year retention)

Cloud Storage pricing for europe-west2:
- Standard: $0.026/GB/month
- Nearline: $0.010/GB/month (access fee: $0.01/GB)
- Coldline: $0.004/GB/month (access fee: $0.02/GB)
- Archive: $0.0012/GB/month (access fee: $0.05/GB)

## Decision

We implement automated lifecycle tiering on the data lake buckets:

| Zone | Initial | 30d → Nearline | 90d → Coldline | 365d → Archive |
|---|---|---|---|---|
| Raw | Standard | ✓ | ✓ | ✓ |
| Curated | Standard | — | ✓ | — |
| Consumption | Standard | — | — | — |
| Transient | Standard | DELETE at 7d | — | — |

## Rationale

### Cost Analysis

At 100TB steady state:

| Strategy | Monthly Cost | Annual Cost |
|---|---|---|
| All Standard | $2,660 | $31,920 |
| With tiering (as above) | $1,080 | $12,960 |
| **Savings** | **$1,580 (59%)** | **$18,960 (59%)** |

85% of our data is >30 days old (historical records). Tiering this to Nearline alone saves ~$820/month.

### Why Not Delete After Retention?

Financial regulations (SEC 17a-4, FCA SYSC) require retaining transaction records for 5-7 years. GDPR requires data minimization but acknowledges legal obligations. Archive storage at $0.0012/GB/month is effectively "cheaper than deleting" — 100TB in Archive costs $120/month.

### Why the Raw Zone Gets All Tiers

The raw zone is immutable (retention policy locked in production). All historical data must be preserved for:
1. Regulatory compliance (7-year retention for financial transactions)
2. Model re-training on full historical data
3. Fraud investigation looking back years (hashed identifiers allow re-identification)

### Why Consumption Zone Stays on Standard

The consumption zone serves business dashboards and APIs that need sub-second query performance. Accessing Coldline data has a 10+ second retrieval delay (unacceptable for a fraud API responding in <500ms).

### Why Transient Zone Deletes After 7 Days

The transient zone is for temporary processing outputs (intermediate Spark/Dataflow results, staging data for quality checks). Data here has zero business value after processing. Auto-deletion at 7 days provides a safety net for debugging failed pipelines.

## Consequences

1. **Positive**: 59% storage cost reduction at steady state (~$18,960/year savings)
2. **Positive**: Automated — no manual data movement, no scripts, no cron jobs
3. **Positive**: Compliance-preserving — Archive storage satisfies regulatory retention without hot storage costs
4. **Negative**: Retrieval costs — Nearline ($0.01/GB), Coldline ($0.02/GB), Archive ($0.05/GB) access fees apply when data is read
5. **Negative**: Retrieval latency — Coldline takes ~10s to retrieve; Archive takes ~1 hour

## Mitigation

- **Hot data caching**: Frequently accessed reference data (lookup tables, model configs) is kept in Standard storage regardless of age via exclusion prefixes
- **Pre-warming for investigations**: When a fraud investigation opens, the relevant transaction files are pre-retrieved from Coldline/Archive to the consumption zone
- **Monitoring**: Cloud Monitoring alert on bucket retrieval costs > 10% of storage cost signals that tiering may be too aggressive

## Related

- Implementation: `modules/data-lake/main.tf`
- ADR-003: Vector Search over Elasticsearch
- Runbook: `docs/runbooks/data-pipeline-dr.md`
