#!/usr/bin/env bash
# E3 — full latency-injection sweep (addresses review CW3: replace the single
# 100 ms point with a {0,25,50,100,250,500} ms x REPS sweep per strategy).
#
# For each (strategy, latency, rep) it brings up the stack, injects `latency` ms
# (with jitter) on that strategy's coordination dependency via Toxiproxy, drives a
# constant-arrival contended load, then appends two tidy rows to
# results/aggregate.csv:
#     E3,<STRATEGY>,lat<ms>-r<i>,p99,<ms>
#     E3,<STRATEGY>,lat<ms>-r<i>,violation_rate,<rate>
# analyze.py detects the multiple latency levels (run prefix 'lat<ms>') and renders
# fig_p99_latency_sweep.png / fig_dsevr_latency_sweep.png as line charts.
#
#   STRATEGIES="DB REDIS ZK" LATENCIES="0 25 50 100 250 500" REPS=3 \
#     scripts/exp_latency_sweep.sh
set -euo pipefail
cd "$(dirname "$0")/.."

STRATEGIES="${STRATEGIES:-DB REDIS ZK KAFKA OUTBOX PAYLOAD_HASH}"
LATENCIES="${LATENCIES:-0 25 50 100 250 500}"
JITTER="${JITTER:-50}"
REPS="${REPS:-3}"
BASE="${BASE:-http://localhost:8080}"
RATE="${RATE:-300}"
DUR="${DUR:-180s}"          # 3-min measurement window per point
NKEYS="${NKEYS:-50}"
AGG="results/aggregate.csv"
mkdir -p results

# Each strategy's coordination dependency -> Toxiproxy proxy to inject latency on.
proxy_for() {
  case "$1" in
    REDIS) echo redis ;;
    ZK)    echo zookeeper ;;
    KAFKA) echo kafka ;;
    *)     echo postgres ;;   # DB, OUTBOX, PAYLOAD_HASH are Postgres-bound
  esac
}

# p99 (ms) from a k6 --summary-export JSON (flat structure; p(99) requires the
# summaryTrendStats option, set in fault_load.js).
p99_from() {
  python3 - "$1" <<'PY'
import json, sys
hrd = json.load(open(sys.argv[1]))["metrics"].get("http_req_duration", {})
print(round(hrd.get("p(99)", hrd.get("p(95)", 0.0)), 6))
PY
}

# DSEVR for a run id, read out-of-band from the audit view via the postgres
# container (host has no psql and 5432 is not published).
dsevr_for() {
  docker compose exec -T postgres psql -U idem -d idemstudy -At \
    -c "SELECT coalesce(max(violation_rate),0) FROM v_violation_rate WHERE experiment_run = '$1';" \
    2>/dev/null | grep -vi warning | head -1 || echo "NA"
}

[ -s "$AGG" ] || echo "scenario,strategy,run,metric,value" > "$AGG"

for strat in $STRATEGIES; do
  proxy="$(proxy_for "$strat")"
  for lat in $LATENCIES; do
    for i in $(seq 1 "$REPS"); do
      run="e3-${strat,,}-lat${lat}-r${i}"
      dir="results/E3/$strat/lat$lat/run$i"
      mkdir -p "$dir"
      echo "==== $run (proxy=$proxy, ${lat}ms +-${JITTER}ms) ===="
      IDEM_STRATEGY="$strat" EXPERIMENT_RUN="$run" docker compose up -d --build
      scripts/wait_healthy.sh
      scripts/faults.sh clear "$proxy" || true
      [ "$lat" -gt 0 ] && scripts/faults.sh latency "$proxy" "$lat" "$JITTER"
      k6 run -e BASE="$BASE" -e RUN="$run" -e RATE="$RATE" -e DUR="$DUR" -e NKEYS="$NKEYS" \
        --summary-export "$dir/k6.json" load-tests/k6/fault_load.js || true
      scripts/faults.sh clear "$proxy" || true

      p99="$(p99_from "$dir/k6.json")"
      vr="$(dsevr_for "$run")"
      echo "E3,$strat,lat${lat}-r${i},p99,$p99" >> "$AGG"
      echo "E3,$strat,lat${lat}-r${i},violation_rate,$vr" >> "$AGG"
      echo "  -> p99=${p99}ms dsevr=${vr}"

      scripts/collect_metrics.sh "$run" "$dir" || true
      docker compose down -v
    done
  done
done
echo "latency sweep complete. Run: python3 analysis/analyze.py  (renders sweep charts)"
