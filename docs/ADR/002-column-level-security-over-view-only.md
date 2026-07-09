# ADR-002: Column-Level Security over View-Only Access

## Status

Accepted

## Context

SecondWave's fraud detection platform ingests PII data (email, phone, national ID, credit card numbers, bank account details) from multiple sources. Under GDPR (Article 5, 25, 32), we must:

1. Restrict PII access to authorized personnel only
2. Ensure all queries — including ad-hoc analyst queries — are protected
3. Maintain audit trails of who accessed what PII
4. Support row-level masking for analysts who need aggregate data

The options are:
1. **BigQuery column-level ACLs** with policy tags from Data Catalog
2. **View-only access** — create views without PII columns and grant view access
3. **Application-layer filtering** — Python/Java SDKs filter PII before returning results

## Decision

We choose **BigQuery column-level ACLs with Data Catalog taxonomy** as the primary mechanism, supplemented by authorized views for common access patterns.

## Rationale

### Why Not View-Only Access?

| Scenario | View-Only | Column ACL |
|---|---|---|
| Analyst runs `SELECT * FROM events` | Returns PII (no view protection on direct table access) | Blocks PII columns automatically |
| Data scientist creates a new ML feature table via `CREATE TABLE ... AS SELECT *` | PII copied to new table (GDPR breach) | Column ACLs propagate to new tables |
| Table schema changes (new column added) | Must update all view definitions (1,200+ views) | Policy tags apply by column name automatically |
| Export to Parquet for Vertex AI training | PII included in export (unless export uses the view) | Column ACLs block PII in exports too |
| Performance | No overhead | Sub-millisecond overhead at query planning time |

### Why Not Application-Layer Filtering?

Application-layer filtering is inherently insecure because:
- It only protects queries through the application — direct BigQuery API access bypasses it
- Every new application or script must re-implement the filtering logic
- Audit logs show the application identity, not the end user's identity
- Accidental log exports could include unfiltered PII

### How Column ACLs Work in This Architecture

```
Data Catalog Taxonomy
  └── PII Classification (activated_policy_types: [FINE_GRAINED_ACCESS_CONTROL])
       └── Sensitive PII
            ├── email (tagged column)
            ├── phone_number (tagged column)
            ├── national_id (tagged column)
            ├── credit_card (tagged column)
            └── bank_account (tagged column — prod only)
```

Each sensitive column is tagged with a policy tag. IAM bindings on the policy tag grant `FINE_GRAINED_READER` access to `group:data-engineering@secondwave.com`. All other users see `NULL` for these columns.

### Row-Level Security

For analysts who need aggregate statistics (e.g., "how many fraud cases involved a given country?"), we add row-level security policies:

```sql
CREATE ROW ACCESS POLICY masked_pii ON events
GRANT TO ('user:analyst@secondwave.com')
FILTER USING (pii_visible = FALSE);
```

When `pii_visible` is `FALSE`, PII columns are replaced with `'MASKED'`. When `TRUE` (e.g., for fraud investigation), the full data is visible.

## Consequences

1. **Positive**: GDPR compliance is audit-verifiable — every column tag and access policy is defined as code
2. **Positive**: Zero maintenance when tables are added — new columns with the same name automatically inherit policy tags
3. **Positive**: Data Catalog taxonomy provides a searchable inventory of all PII, which is required under GDPR Article 30
4. **Negative**: Policy tags add query planning overhead (~10-50ms per query)
5. **Negative**: Requires Data Catalog API to be enabled (minor cost)
6. **Negative**: Some complex queries need manual tag propagation (e.g., `JOIN` with `SELECT *`)

## Mitigation

- Authorized views provide a simplified interface for ML feature engineering — ML engineers never need to know about column ACLs
- The `masked_events` view (see `modules/bigquery/main.tf`) pre-masks PII for the analytics team
- Periodic DLP scans verify that no PII is leaking through unprotected views or exports

## Related

- ADR-001: Composer over Self-Hosted Airflow
- Implementation: `modules/bigquery/main.tf`
- Runbook: `docs/runbooks/bigquery-dataset-restore.md`
