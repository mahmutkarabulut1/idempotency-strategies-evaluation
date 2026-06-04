#!/usr/bin/env bash
# Time-bounded REAL measurement grid for environments without a dedicated test
# host. Produces results/aggregate.csv from live runs. Reduced vs the paper grid:
# short k6 windows, fewer reps. One stack per strategy (E1 reps need no restart;
# E2 correctness uses table truncation), restarting only between strategies.
set -uo pipefail
cd "$(dirname "$0")/.."

STRATS_PERF="${STRATS_PERF:-DB REDIS ZK KAFKA}"
REPS="${REPS:-2}"
NET="idemstudy_default"
K6="grafana/k6:0.52.0"
OUT="results/aggregate.csv"
RAW="results/raw"; mkdir -p "$RAW"
# APPEND=1 keeps existing rows (used to add strategies without re-running others).
if [ "${APPEND:-0}" != 1 ]; then echo "scenario,strategy,run,metric,value" > "$OUT"; fi

PSQL() { docker compose exec -T postgres psql -U idem -d idemstudy -At -F, "$@"; }

k6run() {  # <script> <runtag> <extra-env...>
  local script="$1" tag="$2"; shift 2
  # Run as the host user so the bind-mounted summary file is writable.
  docker run --rm --network "$NET" --user "$(id -u):$(id -g)" "$@" \
    -e BASE=http://nginx:8080 -e RUN="$tag" \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" \
    "$K6" run --quiet --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
    --summary-export "/out/${tag}.json" "/k6/${script}" >/dev/null 2>&1
  echo "$RAW/${tag}.json"
}

jqv() { jq -r "$2 // 0" "$1" 2>/dev/null; }

wait_up() {
  local d=$(( $(date +%s) + 200 ))
  until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do
    [ "$(date +%s)" -gt "$d" ] && { echo "  TIMEOUT waiting for stack"; return 1; }
    sleep 3
  done
}

docker pull "$K6" >/dev/null 2>&1 || true

for S in $STRATS_PERF; do
  echo "==== strategy $S ===="
  IDEM_STRATEGY="$S" EXPERIMENT_RUN="grid-$S" docker compose down -v >/dev/null 2>&1
  IDEM_STRATEGY="$S" EXPERIMENT_RUN="grid-$S" docker compose up -d >/dev/null 2>&1
  wait_up || { echo "  skip $S"; continue; }
  active=$(curl -s http://localhost:8080/operations/strategy)
  echo "  active=$active"

  # ---- E1 performance: REPS k6 runs, no restart ----
  for i in $(seq 1 "$REPS"); do
    f=$(k6run baseline_smoke.js "e1-${S}-run${i}" -e DUP_RATIO=0.10)
    thr=$(jqv "$f" '.metrics.http_reqs.rate')
    p99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]')
    p95=$(jqv "$f" '.metrics.http_req_duration["p(95)"]')
    echo "E1,$S,run${i},throughput,$thr" >> "$OUT"
    echo "E1,$S,run${i},p99,$p99" >> "$OUT"
    echo "E1,$S,run${i},p95,$p95" >> "$OUT"
    echo "  E1 run$i: thr=$thr p99=$p99"
  done

  # ---- E2 correctness: clean tables, duplicate burst, measure DSEVR ----
  # Scope all E2 counts to the burst's own keys ('e2-<S>-op-%') so residual E1
  # side effects and (for async strategies) an unprocessed backlog cannot pollute
  # the denominator. For KAFKA/OUTBOX, wait until the consumer fully drains.
  # Only TRUNCATE for synchronous strategies. For async (KAFKA/OUTBOX) the consumer
  # holds row locks while draining E1's backlog, and TRUNCATE's ACCESS EXCLUSIVE
  # lock deadlocks against it; key-scoped counting below makes TRUNCATE unnecessary.
  case "$S" in KAFKA|OUTBOX) : ;; *) PSQL -c "TRUNCATE operation_side_effects, idempotency_records, processed_messages RESTART IDENTITY;" >/dev/null 2>&1 ;; esac
  f=$(k6run duplicate-burst.js "e2-${S}" -e BURST=50 -e OPS=200)
  case "$S" in
    KAFKA|OUTBOX)
      prev=-1; stable=0; dl=$(( $(date +%s) + 180 ))
      while [ "$(date +%s)" -lt "$dl" ]; do
        c=$(PSQL -c "SELECT count(*) FROM processed_messages;"); c=${c:-0}
        if [ "$c" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi
        [ "$stable" -ge 3 ] && break; prev=$c; sleep 3
      done ;;
    *) sleep 3 ;;
  esac
  K="e2-${S}-op-%"
  logical=$(PSQL -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE '$K';")
  total=$(PSQL -c   "SELECT count(*) FROM operation_side_effects WHERE idempotency_key LIKE '$K';")
  viol=$(PSQL -c    "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE '$K' GROUP BY operation_id HAVING count(*)>1) t;")
  logical=${logical:-0}; viol=${viol:-0}; total=${total:-0}
  rate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{ if(l>0) printf "%.6f", v/l; else print "0" }')
  burst_p99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]')
  echo "E2,$S,run1,violation_rate,$rate" >> "$OUT"
  echo "E2,$S,run1,p99,$burst_p99" >> "$OUT"
  echo "E2,$S,run1,side_effects_total,$total" >> "$OUT"
  echo "E2,$S,run1,logical_ops,$logical" >> "$OUT"
  echo "  E2 $S: logical=$logical total=$total violations=$viol rate=$rate"
done

echo "==== done -> $OUT ===="
cat "$OUT"
