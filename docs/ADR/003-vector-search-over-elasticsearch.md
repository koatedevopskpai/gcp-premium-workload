# ADR-003: Vertex AI Vector Search over Elasticsearch for Semantic Search

## Status

Accepted

## Context

SecondWave's fraud detection platform needs to find semantically similar transactions and claims. Use cases:

1. **Fraud ring detection**: Given a flagged transaction, find 50 most similar historical transactions
2. **Claim similarity**: Identify repeat claims from the same entity using different identifiers
3. **Anomaly detection**: Flag transactions whose embeddings are far from known fraud patterns
4. **Investigation support**: Fraud analysts query by transaction narrative to find similar cases

All transactions are converted to 768-dimensional embeddings via Vertex AI `textembedding-gecko@003`. We need an approximate nearest neighbor (ANN) service with:
- Sub-10ms P99 latency
- 10M+ vector scale
- 95%+ recall
- VPC-SC compatible
- Native GCP integration

Options:
1. **Vertex AI Vector Search** (managed ANN by Google)
2. **Elasticsearch with dense vector plugin** (self-managed on GKE)
3. **pgvector on Cloud SQL / AlloyDB**
4. **Custom Faiss service on GKE**

## Decision

We choose **Vertex AI Vector Search** with Tree-AH (ScANN) algorithm.

## Rationale

### Comparison

| Factor | Vertex AI Vector Search | Elasticsearch + ANN | pgvector | Custom Faiss |
|---|---|---|---|---|
| **Latency (P99, 10M vectors)** | ~8ms | ~25ms (with ANN plugin) | ~50ms (IVFFlat) | ~15ms (optimized) |
| **Recall @ 10** | 95-97% | 90-95% | 85-92% | 95-99% (tunable) |
| **Setup time** | 2 hours | 2 days (cluster + plugin + tuning) | 1 day | 2 weeks |
| **Operations** | Serverless — no cluster to manage | Cluster health, shard rebalancing, JVM tuning | PostgreSQL vacuum, index rebuilds | Custom deployment, autoscaling, monitoring |
| **Cost (10M vectors, 100QPS)** | ~$800/month | ~$1,800/month (3-node Elastic Cloud) | ~$500/month (2 vCPU AlloyDB) | ~$600/month (GKE + GPUs) |
| **VPC-SC** | Native support | Requires manual perimeter config | Native (Cloud SQL) | Requires manual config |
| **Vertex AI integration** | Native — embeddings → index → query in one API | Requires custom ETL pipeline | Requires custom pipeline | Requires custom pipeline |
| **Scaling** | Automatic shard scaling | Manual index management | Scaling limit at ~10M vectors | Full custom control |
| **Multi-tenancy** | Namespaced indexes | Native | Database-per-tenant | Custom |

### Why Not Elasticsearch?

Elasticsearch is excellent for full-text search but suboptimal for ANN at scale:

1. **Latency**: Dense vector search in Elasticsearch uses HNSW, which requires keeping the entire graph in memory. At 10M 768-dimensional vectors, that's ~30GB of heap — requiring large instances and careful JVM tuning (which the platform team doesn't have expertise in).

2. **Cost**: Elastic Cloud's minimum viable ANN cluster (3 x 16GB nodes) costs ~$1,800/month. Vector Search at similar throughput is ~$800/month.

3. **Data movement**: Elasticsearch requires replicating data from GCP to the Elasticsearch cluster. Vector Search queries the index directly from Vertex AI without data movement.

### Why Not pgvector?

pgvector works well for <1M vectors but degrades significantly beyond 5M. For SecondWave's 10M+ fraud vectors, the IVFFlat algorithm in pgvector requires 0.5s+ queries at 90% recall — unacceptable for real-time fraud scoring.

### Why Not Custom Faiss?

Custom Faiss on GKE provides maximum control but requires:
- Kubernetes infrastructure expertise (limited in the 5-person platform team)
- Custom query API (gRPC or REST)
- Pod autoscaling based on GPU memory
- Backup/recovery for the index
- Monitoring and alerting

The team would spend 2 months building and tuning this — time better spent on ML model improvements.

## Consequences

1. **Positive**: Sub-10ms similarity search with zero infrastructure management
2. **Positive**: End-to-end Vertex AI workflow: embeddings → index → query → fraud API
3. **Positive**: Automatic scaling from 0 to 100K+ QPS
4. **Negative**: Vendor lock-in — migrating to custom Faiss requires rewriting the query layer
5. **Negative**: Limited algorithm choice (Tree-AH, Brute Force only; no HNSW)
6. **Negative**: Index updates are eventually consistent (5-10 min delay for batch updates)

## Mitigation

- Query layer is abstracted behind a gRPC interface. If needed, we can swap the backend without changing ML model code
- For real-time fraud scoring where 10-minute index lag is unacceptable, we maintain a small in-memory Faiss cache for the last 24 hours of embeddings
- Vector Search indexes are backed up to Cloud Storage weekly

## Related

- Implementation: `modules/vector-search/main.tf`
- ADR-004: Data Lake Lifecycle for Cost
