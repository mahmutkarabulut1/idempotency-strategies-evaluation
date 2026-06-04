#!/usr/bin/env bash
# Completes coverage: OUTBOX + PAYLOAD_HASH (E1/E2 via smoke_grid APPEND), then
# E3 (latency injection), E6 (Kafka consumer crash / redelivery), E7 (conflicting
# payload). Appends rows to results/aggregate.csv, then re-runs analysis.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
CF="-f docker-compose.yml -f docker-compose.override.yml"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }
prom(){ curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null; }
jqv(){ jq -r "$2 // 0" "$1" 2>/dev/null; }
dep_for(){ case "$1" in DB) echo postgres;; REDIS) echo redis;; ZK) echo zookeeper;; *) echo postgres;; esac; }
wait_up(){ local d=$(( $(date +%s)+220 )); until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do [ "$(date +%s)" -gt "$d" ] && return 1; sleep 3; done; }
upS(){ local S=$1; IDEM_STRATEGY=$S EXPERIMENT_RUN=rem-$S docker compose $CF down -v >/dev/null 2>&1
       IDEM_STRATEGY=$S EXPERIMENT_RUN=rem-$S docker compose $CF up -d >/dev/null 2>&1; wait_up; }

# ---------- (1) OUTBOX + PAYLOAD_HASH : E1 + E2 ----------
echo "### REMAINING STRATEGIES (OUTBOX, PAYLOAD_HASH) E1/E2 ###"
APPEND=1 STRATS_PERF="OUTBOX PAYLOAD_HASH" REPS=2 bash scripts/smoke_grid.sh 2>&1 | grep -E 'strategy|E1 run|E2 ' || true

# ---------- (2) E3 latency injection (100ms on the strategy dependency) ----------
echo "### E3 LATENCY INJECTION (100ms) ###"
[ -f "$AGG" ] && { grep -v '^E3,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"; }
for S in DB REDIS ZK; do
  dep=$(dep_for "$S")
  echo "==== E3 $S (dep=$dep +100ms) ===="
  upS "$S" || { echo "  skip"; continue; }
  scripts/faults.sh latency "$dep" 100 20 >/dev/null 2>&1
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=e3-$S -e DUP_RATIO=0.10 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-trend-stats="avg,p(95),p(99),max" \
    --summary-export /out/e3-$S.json /k6/baseline_smoke.js >/dev/null 2>&1
  scripts/faults.sh clear "$dep" >/dev/null 2>&1
  p99=$(jqv $RAW/e3-$S.json '.metrics.http_req_duration["p(99)"]')
  p95=$(jqv $RAW/e3-$S.json '.metrics.http_req_duration["p(95)"]')
  thr=$(jqv $RAW/e3-$S.json '.metrics.http_reqs.rate')
  { echo "E3,$S,run1,p99,$p99"; echo "E3,$S,run1,p95,$p95"; echo "E3,$S,run1,throughput,$thr"; } >> "$AGG"
  echo "  E3 $S: p99=$p99 thr=$thr"
done

# ---------- (3) E6 Kafka consumer crash / redelivery ----------
echo "### E6 KAFKA CONSUMER CRASH / REDELIVERY ###"
[ -f "$AGG" ] && { grep -v '^E6,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"; }
if upS KAFKA; then
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=e6 -e RATE=200 -e DUR=45s -e NKEYS=300 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-export /out/e6.json /k6/fault_load.js >/dev/null 2>&1 &
  K6PID=$!
  sleep 12; echo "  SIGKILL svc2 (mid-processing)"; docker compose $CF kill -s SIGKILL svc2 >/dev/null 2>&1
  sleep 3;  docker compose $CF up -d svc2 >/dev/null 2>&1
  wait $K6PID 2>/dev/null || true
  # drain consumer
  prev=-1; stable=0; dl=$(( $(date +%s)+180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do c=$(P -c "SELECT count(*) FROM processed_messages;"); c=${c:-0}
    if [ "$c" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi; [ "$stable" -ge 3 ] && break; prev=$c; sleep 3; done
  redel=$(prom 'sum(message_redeliveries_total)'); dupsupp=$(prom 'sum(idempotency_duplicates_total)')
  logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE 'flt-e6-%';")
  viol=$(P -c "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE 'flt-e6-%' GROUP BY operation_id HAVING count(*)>1) t;")
  logical=${logical:-0}; viol=${viol:-0}; redel=${redel:-0}; dupsupp=${dupsupp:-0}
  vrate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{print (l>0)?v/l:0}')
  { echo "E6,KAFKA,run1,violation_rate,$vrate"; echo "E6,KAFKA,run1,redeliveries,$redel"
    echo "E6,KAFKA,run1,duplicates_suppressed,$dupsupp"; echo "E6,KAFKA,run1,logical_ops,$logical"; } >> "$AGG"
  echo "  E6 KAFKA: redeliveries=$redel dup_suppressed=$dupsupp logical=$logical viol=$viol vrate=$vrate"
else echo "  skip E6"; fi

# ---------- (4) E7 conflicting payload (PAYLOAD_HASH vs DB) ----------
echo "### E7 CONFLICTING PAYLOAD ###"
[ -f "$AGG" ] && { grep -v '^E7,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"; }
for S in PAYLOAD_HASH DB; do
  echo "==== E7 $S ===="
  upS "$S" || { echo "  skip"; continue; }
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=e7-$S \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-export /out/e7-$S.json /k6/conflict.js >/dev/null 2>&1
  cc=$(jqv $RAW/e7-$S.json '.metrics.correct_conflict.count')
  ir=$(jqv $RAW/e7-$S.json '.metrics.incorrect_replay.count')
  acc=$(awk -v c="$cc" -v i="$ir" 'BEGIN{d=c+i; print (d>0)?c/d:0}')
  { echo "E7,$S,run1,conflict_accuracy,$acc"; echo "E7,$S,run1,correct_conflict,$cc"
    echo "E7,$S,run1,incorrect_replay,$ir"; } >> "$AGG"
  echo "  E7 $S: correct=$cc incorrect=$ir accuracy=$acc"
done

echo "### ANALYSIS ###"
python3 analysis/analyze.py 2>&1 | tail -8
python3 analysis/make_results_table.py >/dev/null 2>&1
echo "### REMAINING EXPERIMENTS COMPLETE ###"
