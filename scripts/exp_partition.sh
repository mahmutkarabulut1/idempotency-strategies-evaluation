#!/usr/bin/env bash
# E4 — Network partition. For each strategy: fresh stack, sustained contended
# load, partition the strategy's coordination dependency mid-run, then measure
# DSEVR (scoped to the load's keys), request error rate, and API recovery time.
# Appends E4,* rows to results/aggregate.csv.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
STRATS="${STRATS:-DB REDIS ZK}"; PART_SECS="${PART_SECS:-8}"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }
dep_for(){ case "$1" in DB) echo postgres;; REDIS) echo redis;; ZK) echo zookeeper;; esac; }
secs_since(){ awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }

[ -f "$AGG" ] && { grep -v '^E4,' "$AGG" > "$AGG.tmp"; mv "$AGG.tmp" "$AGG"; }

for S in $STRATS; do
  dep=$(dep_for "$S"); RUN=p-$S
  echo "==== E4 partition: strategy=$S dep=$dep ===="
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e4-$S docker compose down -v >/dev/null 2>&1
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e4-$S docker compose up -d >/dev/null 2>&1
  d=$(( $(date +%s)+220 )); ok=1
  until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do
    [ "$(date +%s)" -gt "$d" ] && { echo "  boot timeout, skip $S"; ok=0; break; }; sleep 3; done
  [ "$ok" = 0 ] && continue

  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=$RUN -e RATE=250 -e DUR=60s -e NKEYS=50 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-trend-stats="avg,p(95),p(99),max" \
    --summary-export /out/e4-$S.json /k6/fault_load.js >/dev/null 2>&1 &
  K6PID=$!
  sleep 20
  echo "  partitioning $dep for ${PART_SECS}s (mid-load)"
  scripts/faults.sh partition "$dep" "$PART_SECS" >/dev/null 2>&1

  # recovery: time from partition-clear until a write succeeds again
  rec_start=$(date +%s.%N)
  REQ='{"idempotencyKey":"rec-'$S'","operationType":"PAYMENT","entityId":"e","userId":"u","amount":1,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"rec"}'
  while true; do
    curl -fsS -o /dev/null -X POST http://localhost:8080/operations \
      -H 'Content-Type: application/json' -d "$REQ" 2>/dev/null && break
    [ "$(awk -v a="$rec_start" -v b="$(date +%s.%N)" 'BEGIN{print (b-a>30)?1:0}')" = 1 ] && break
    sleep 0.2
  done
  rec=$(secs_since "$rec_start")
  wait $K6PID 2>/dev/null || true

  f=$RAW/e4-$S.json
  rej=$(jq -r '.metrics.op_rejected.count // 0' "$f"); err=$(jq -r '.metrics.op_error.count // 0' "$f")
  reqs=$(jq -r '.metrics.http_reqs.count // 0' "$f")
  errrate=$(awk -v e="$err" -v r="$rej" -v t="$reqs" 'BEGIN{print (t>0)?(e+r)/t:0}')
  logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE 'flt-$RUN-%';")
  viol=$(P -c "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE 'flt-$RUN-%' GROUP BY operation_id HAVING count(*)>1) t;")
  logical=${logical:-0}; viol=${viol:-0}
  vrate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{print (l>0)?v/l:0}')
  { echo "E4,$S,run1,violation_rate,$vrate"
    echo "E4,$S,run1,error_rate,$errrate"
    echo "E4,$S,run1,recovery_s,$rec"
    echo "E4,$S,run1,logical_ops,$logical"; } >> "$AGG"
  printf "  E4 %s: logical=%s viol=%s vrate=%s errrate=%.3f recovery=%ss\n" "$S" "$logical" "$viol" "$vrate" "$errrate" "$rec"
done
echo "==== E4 done ===="
