#!/usr/bin/env bash
# Final clean-up re-measurements:
#   (A) E2 denominators for async/affected strategies (OUTBOX, KAFKA, PAYLOAD_HASH)
#   (B) E7 conflict detection at LOW concurrency (so first request commits)
# then regenerate figures/tables. Appends/replaces rows in results/aggregate.csv.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
CF="-f docker-compose.yml -f docker-compose.override.yml"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }
jqv(){ jq -r "$2 // 0" "$1" 2>/dev/null; }
wait_up(){ local d=$(( $(date +%s)+220 )); until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do [ "$(date +%s)" -gt "$d" ] && return 1; sleep 3; done; }

echo "### (A) clean E2 denominators ###"
bash scripts/fix_async_e2.sh OUTBOX KAFKA PAYLOAD_HASH

echo "### (B) E7 conflict detection at low concurrency ###"
[ -f "$AGG" ] && { grep -v '^E7,' "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"; }
for S in PAYLOAD_HASH DB; do
  echo "==== E7 $S (5 VUs) ===="
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e7-$S docker compose $CF down -v >/dev/null 2>&1
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e7-$S docker compose $CF up -d >/dev/null 2>&1
  wait_up || { echo "  skip"; continue; }
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=e7c-$S -e VUS=5 -e ITER=2000 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-export /out/e7c-$S.json /k6/conflict.js >/dev/null 2>&1
  fa=$(jqv $RAW/e7c-$S.json '.metrics.first_applied.count')
  cc=$(jqv $RAW/e7c-$S.json '.metrics.correct_conflict.count')
  ir=$(jqv $RAW/e7c-$S.json '.metrics.incorrect_replay.count')
  acc=$(awk -v c="$cc" -v i="$ir" 'BEGIN{d=c+i; print (d>0)?c/d:0}')
  cond=$(awk -v c="$cc" -v f="$fa" 'BEGIN{print (f>0)?c/f:0}')   # accuracy given r1 committed
  { echo "E7,$S,run1,conflict_accuracy,$acc"
    echo "E7,$S,run1,conflict_accuracy_committed,$cond"
    echo "E7,$S,run1,correct_conflict,$cc"
    echo "E7,$S,run1,incorrect_replay,$ir"
    echo "E7,$S,run1,first_applied,$fa"; } >> "$AGG"
  echo "  E7 $S: first_applied=$fa correct=$cc incorrect=$ir accuracy=$acc accuracy|committed=$cond"
done

echo "### analysis ###"
python3 analysis/analyze.py 2>&1 | tail -10
python3 analysis/make_results_table.py >/dev/null 2>&1
echo "### FINALIZE REMEASURES COMPLETE ###"
