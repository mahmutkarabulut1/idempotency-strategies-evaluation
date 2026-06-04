#!/usr/bin/env bash
# Clean, drain-aware KAFKA E2 measurement. Restarts the KAFKA stack fresh, sends
# one duplicate burst, waits until the async consumer fully drains (processed-row
# count stable), then counts side effects scoped to the burst keys. Updates the
# E2 KAFKA rows in results/aggregate.csv.
set -uo pipefail
cd "$(dirname "$0")/.."
NET="idemstudy_default"; K6="grafana/k6:0.52.0"; RAW="results/raw"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }

echo "[kafka-e2] restarting KAFKA stack fresh"
IDEM_STRATEGY=KAFKA EXPERIMENT_RUN=grid-KAFKA docker compose down -v >/dev/null 2>&1
IDEM_STRATEGY=KAFKA EXPERIMENT_RUN=grid-KAFKA docker compose up -d >/dev/null 2>&1
d=$(( $(date +%s) + 200 ))
until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do
  [ "$(date +%s)" -gt "$d" ] && { echo "[kafka-e2] boot timeout"; exit 1; }; sleep 3; done
echo "[kafka-e2] active=$(curl -s http://localhost:8080/operations/strategy)"

echo "[kafka-e2] running burst (200 keys x 50)"
docker run --rm --network "$NET" --user "$(id -u):$(id -g)" \
  -e BASE=http://nginx:8080 -e RUN=e2clean-KAFKA -e BURST=50 -e OPS=200 \
  -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" "$K6" \
  run --quiet --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
  --summary-export /out/e2clean-KAFKA.json /k6/duplicate-burst.js >/dev/null 2>&1

echo "[kafka-e2] waiting for consumer to drain (processed-row count stable)"
prev=-1; stable=0; deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  cur=$(P -c "SELECT count(*) FROM processed_messages;"); cur=${cur:-0}
  if [ "$cur" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi
  [ "$stable" -ge 3 ] && break
  prev=$cur; sleep 3
done
echo "[kafka-e2] drained at processed=$prev rows"

logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE 'e2clean-KAFKA-op-%';")
total=$(P -c   "SELECT count(*) FROM operation_side_effects WHERE idempotency_key LIKE 'e2clean-KAFKA-op-%';")
viol=$(P -c    "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE 'e2clean-KAFKA-op-%' GROUP BY operation_id HAVING count(*)>1) t;")
logical=${logical:-0}; total=${total:-0}; viol=${viol:-0}
rate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{ if(l>0) printf "%.6f", v/l; else print "0" }')
p99=$(jq -r '.metrics.http_req_duration["p(99)"] // 0' "$RAW/e2clean-KAFKA.json" 2>/dev/null)
echo "[kafka-e2] RESULT logical=$logical total=$total violations=$viol rate=$rate p99=$p99"

# Replace the E2,KAFKA,* rows in aggregate.csv with clean values.
AGG=results/aggregate.csv
grep -v '^E2,KAFKA,' "$AGG" > "$AGG.tmp"
{
  echo "E2,KAFKA,run1,violation_rate,$rate"
  echo "E2,KAFKA,run1,p99,$p99"
  echo "E2,KAFKA,run1,side_effects_total,$total"
  echo "E2,KAFKA,run1,logical_ops,$logical"
} >> "$AGG.tmp"
mv "$AGG.tmp" "$AGG"
echo "[kafka-e2] updated $AGG"
