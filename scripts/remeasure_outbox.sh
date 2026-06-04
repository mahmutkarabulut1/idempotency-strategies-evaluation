#!/usr/bin/env bash
# Rebuild after the outbox jsonb->text fix and re-measure OUTBOX E1 + E2 properly
# (the prior numbers were HTTP 500s). Updates E1,OUTBOX and E2,OUTBOX rows.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
CF="-f docker-compose.yml -f docker-compose.override.yml"
P(){ docker compose $CF exec -T postgres psql -U idem -d idemstudy -At -c "$1" 2>/dev/null | grep -v warning; }
jqv(){ jq -r "$2 // 0" "$1" 2>/dev/null; }
wait_up(){ local d=$(( $(date +%s)+220 )); until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do [ "$(date +%s)" -gt "$d" ] && return 1; sleep 3; done; }

echo "### rebuild ###"
mvn -q -DskipTests package 2>&1 | tail -2
docker compose build svc1 svc2 svc3 2>&1 | grep -iE 'built|error' | tail -3

echo "### fresh OUTBOX stack ###"
IDEM_STRATEGY=OUTBOX EXPERIMENT_RUN=ob docker compose $CF down -v >/dev/null 2>&1
IDEM_STRATEGY=OUTBOX EXPERIMENT_RUN=ob docker compose $CF up -d >/dev/null 2>&1
wait_up || { echo "boot timeout"; exit 1; }

# boot correctness: submit -> 201, then side effect appears via relay+consumer
B='{"idempotencyKey":"obchk","operationType":"PAYMENT","entityId":"e","userId":"u","amount":5,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"chk"}'
code=$(curl -s -o /dev/null -w '%{http_code}' -XPOST localhost:8080/operations -H 'Content-Type: application/json' -d "$B")
echo "submit code=$code (expect 201)"
for i in $(seq 1 20); do se=$(P "SELECT count(*) FROM operation_side_effects WHERE idempotency_key='obchk';"); [ "${se:-0}" -ge 1 ] && break; sleep 1; done
echo "boot side effect for obchk=$se (expect 1); outbox_events=$(P "SELECT status||':'||count(*) FROM outbox_events GROUP BY status;")"
[ "${se:-0}" -ge 1 ] || { echo "OUTBOX STILL BROKEN"; docker compose $CF logs svc1 2>&1 | grep -iE 'error|exception' | tail -8; exit 1; }

echo "### E1 (2 reps) ###"
grep -v '^E1,OUTBOX,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"
for i in 1 2; do
  docker run --rm --network $NET --user "$(id -u):$(id -g)" -e BASE=http://nginx:8080 -e DUP_RATIO=0.10 -e RUN=e1-OUTBOX-r$i \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 run --quiet \
    --summary-trend-stats="avg,p(95),p(99),max" --summary-export /out/e1-OUTBOX-r$i.json /k6/baseline_smoke.js >/dev/null 2>&1
  thr=$(jqv $RAW/e1-OUTBOX-r$i.json '.metrics.http_reqs.rate'); p99=$(jqv $RAW/e1-OUTBOX-r$i.json '.metrics.http_req_duration["p(99)"]'); p95=$(jqv $RAW/e1-OUTBOX-r$i.json '.metrics.http_req_duration["p(95)"]')
  { echo "E1,OUTBOX,run$i,throughput,$thr"; echo "E1,OUTBOX,run$i,p99,$p99"; echo "E1,OUTBOX,run$i,p95,$p95"; } >> "$AGG"
  echo "  E1 OUTBOX run$i: thr=$thr p99=$p99"
done

echo "### E2 (burst + drain) ###"
grep -v '^E2,OUTBOX,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"
P "TRUNCATE operation_side_effects, idempotency_records, processed_messages, outbox_events RESTART IDENTITY;" >/dev/null 2>&1
docker run --rm --network $NET --user "$(id -u):$(id -g)" -e BASE=http://nginx:8080 -e RUN=e2cOB -e BURST=50 -e OPS=200 \
  -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 run --quiet --summary-export /out/e2cOB.json /k6/duplicate-burst.js >/dev/null 2>&1
prev=-1; stable=0; seen=0; dl=$(( $(date +%s)+240 ))
while [ "$(date +%s)" -lt "$dl" ]; do c=$(P "SELECT count(*) FROM processed_messages;"); c=${c:-0}
  [ "$c" -gt 0 ] && seen=1
  if [ "$c" = "$prev" ] && [ "$seen" = 1 ]; then stable=$((stable+1)); else stable=0; fi
  [ "$stable" -ge 4 ] && break; prev=$c; sleep 3; done
echo "  drained at processed=$prev (seen=$seen)"
logical=$(P "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE 'e2cOB-op-%';")
total=$(P "SELECT count(*) FROM operation_side_effects WHERE idempotency_key LIKE 'e2cOB-op-%';")
viol=$(P "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE 'e2cOB-op-%' GROUP BY operation_id HAVING count(*)>1) t;")
p99=$(jqv $RAW/e2cOB.json '.metrics.http_req_duration["p(99)"]')
logical=${logical:-0}; total=${total:-0}; viol=${viol:-0}
rate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{print (l>0)?v/l:0}')
{ echo "E2,OUTBOX,run1,violation_rate,$rate"; echo "E2,OUTBOX,run1,p99,$p99"
  echo "E2,OUTBOX,run1,side_effects_total,$total"; echo "E2,OUTBOX,run1,logical_ops,$logical"; } >> "$AGG"
echo "  E2 OUTBOX: logical=$logical total=$total viol=$viol rate=$rate"

echo "### analysis ###"
python3 analysis/analyze.py 2>&1 | tail -10
python3 analysis/make_results_table.py >/dev/null 2>&1
echo "### OUTBOX REMEASURE COMPLETE ###"
