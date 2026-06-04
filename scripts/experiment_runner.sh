#!/usr/bin/env bash
# Orchestrates the full experiment grid: every strategy x every scenario,
# repeated R times, with warm-up / measurement / cooldown windows. Results land
# in results/<scenario>/<strategy>/run<i>/.
#
#   STRATEGIES="DB REDIS ZK KAFKA OUTBOX" SCENARIOS="E1 E2" REPS=3 scripts/experiment_runner.sh
set -euo pipefail
cd "$(dirname "$0")/.."

STRATEGIES="${STRATEGIES:-DB REDIS ZK KAFKA OUTBOX PAYLOAD_HASH}"
SCENARIOS="${SCENARIOS:-E1 E2 E3 E4 E5 E6 E7}"
REPS="${REPS:-3}"
BASE="${BASE:-http://localhost:8080}"
OUT="results"
mkdir -p "$OUT"

run_scenario() {
  local scn="$1" strat="$2" run="$3" dir="$4"
  case "$scn" in
    E1) k6 run -e BASE="$BASE" -e DUP_RATIO=0.05 -e RUN="$run" \
          --summary-export "$dir/k6.json" load-tests/k6/baseline.js ;;
    E2) for b in 10 50 100 500; do
          k6 run -e BASE="$BASE" -e BURST=$b -e OPS=500 -e RUN="${run}-b${b}" \
            --summary-export "$dir/k6-b${b}.json" load-tests/k6/duplicate-burst.js
        done ;;
    E3) for lat in 0 25 50 100 250 500; do
          scripts/faults.sh clear redis || true
          [ "$lat" -gt 0 ] && scripts/faults.sh latency redis "$lat" 50
          k6 run -e BASE="$BASE" -e DUP_RATIO=0.05 -e RUN="${run}-lat${lat}" \
            --summary-export "$dir/k6-lat${lat}.json" load-tests/k6/baseline.js
          scripts/faults.sh clear redis || true
        done ;;
    E4) ( sleep 120; for d in 0.5 1 2 5 10; do
            scripts/faults.sh partition redis "$d"; sleep 20; done ) &
        k6 run -e BASE="$BASE" -e BURST=100 -e OPS=500 -e RUN="$run" \
          --summary-export "$dir/k6.json" load-tests/k6/duplicate-burst.js ;;
    E5) ( sleep 120; scripts/clock_drift.sh svc1 +0.5 ) &
        k6 run -e BASE="$BASE" -e BURST=100 -e OPS=500 -e RUN="$run" \
          --summary-export "$dir/k6.json" load-tests/k6/duplicate-burst.js
        scripts/clock_drift.sh svc1 reset || true ;;
    E6) ( sleep 60; scripts/kafka_crash.sh svc2 before; sleep 30
          scripts/kafka_crash.sh svc3 after ) &
        k6 run -e BASE="$BASE" -e DUP_RATIO=0.0 -e RUN="$run" \
          --summary-export "$dir/k6.json" load-tests/k6/baseline.js ;;
    E7) k6 run -e BASE="$BASE" -e RUN="$run" \
          --summary-export "$dir/k6.json" load-tests/k6/conflict.js ;;
  esac
}

for scn in $SCENARIOS; do
  for strat in $STRATEGIES; do
    # E5/E6 are not meaningful for every strategy but we run all for completeness.
    for i in $(seq 1 "$REPS"); do
      run="${scn,,}-${strat,,}-run${i}"
      dir="$OUT/$scn/$strat/run$i"
      mkdir -p "$dir"
      echo "==== $run ===="
      IDEM_STRATEGY="$strat" EXPERIMENT_RUN="$run" docker compose up -d --build
      scripts/wait_healthy.sh
      run_scenario "$scn" "$strat" "$run" "$dir"
      scripts/collect_metrics.sh "$run" "$dir"
      docker compose down -v
    done
  done
done
echo "all experiments complete -> $OUT/"
