#!/usr/bin/env bash
# Exports Prometheus instant queries + DB correctness ground-truth for one run.
set -euo pipefail
RUN="${1:?run id}"
DIR="${2:?output dir}"
PROM="${PROM:-http://localhost:9090}"
PGURL="${PGURL:-postgresql://idem:idem@localhost:5432/idemstudy}"
mkdir -p "$DIR"

q() {  # prometheus instant query -> file
  curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | jq -r '.data.result' > "$DIR/$2.json"
}

# ---- performance metrics (Prometheus) ----
q 'histogram_quantile(0.50, sum(rate(operation_processing_duration_seconds_bucket[1m])) by (le,strategy))' p50
q 'histogram_quantile(0.95, sum(rate(operation_processing_duration_seconds_bucket[1m])) by (le,strategy))' p95
q 'histogram_quantile(0.99, sum(rate(operation_processing_duration_seconds_bucket[1m])) by (le,strategy))' p99
q 'sum(rate(idempotency_requests_total[1m]))' throughput
q 'histogram_quantile(0.99, sum(rate(lock_acquisition_duration_seconds_bucket[1m])) by (le))' lock_p99
q 'sum(lock_timeout_total)'              lock_timeouts
q 'sum(stale_lock_total)'                stale_locks
q 'sum(premature_lock_expiration_total)' premature_expirations
q 'sum(message_redeliveries_total)'      redeliveries
q 'sum(duplicate_side_effect_violations_total)' violations_live

# ---- resource utilization (addresses review SW1) ----
# Per-strategy CPU, heap, DB connection-pool saturation, and consumer lag, so the
# "ZooKeeper is more expensive" claim becomes a measured statement (e.g. CPU x DB)
# rather than an inference from latency.
q 'avg by (strategy) (process_cpu_usage)'                                  cpu_usage
q 'sum by (strategy) (jvm_memory_used_bytes{area="heap"})'                 heap_used_bytes
q 'avg by (strategy) (system_load_average_1m)'                             load_avg_1m
q 'max by (strategy) (hikaricp_connections_active)'                        db_pool_active
q 'max by (strategy) (hikaricp_connections_max)'                           db_pool_max
q 'max by (strategy) (hikaricp_connections_pending)'                       db_pool_pending
q 'max(kafka_consumer_fetch_manager_records_lag_max)'                      consumer_lag

# ---- correctness ground truth (PostgreSQL) ----
psql "$PGURL" -v run="$RUN" -At -f scripts/correctness_queries.sql > "$DIR/correctness.csv" 2>/dev/null \
  || echo "psql unavailable; skip DB ground truth"

echo "collected metrics for $RUN -> $DIR"
