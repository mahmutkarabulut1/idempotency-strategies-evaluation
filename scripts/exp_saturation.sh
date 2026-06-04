#!/usr/bin/env bash
# E1-S — Open-loop saturation sweep (addresses review CW2). For each strategy,
# steps the offered request rate and records achieved throughput + error rate at
# each step, so each strategy's maximum sustainable rate (error rate < 1%) — the
# "knee" — can be read off. This replaces the non-discriminating closed-loop
# throughput convergence (~776 req/s for every strategy) with a real per-strategy
# ceiling. Writes results/saturation.csv:
#     offered_rate,strategy,run,achieved_rps,error_rate,p99
# analyze.py renders fig_saturation.png (throughput vs offered rate, knee marked).
#
#   STRATEGIES="DB REDIS ZK KAFKA" RATES="500 1000 2000 4000 6000 8000 10000" \
#     REPS=3 scripts/exp_saturation.sh
set -euo pipefail
cd "$(dirname "$0")/.."

STRATEGIES="${STRATEGIES:-DB REDIS ZK KAFKA OUTBOX PAYLOAD_HASH}"
RATES="${RATES:-500 1000 2000 4000 6000 8000 10000}"
REPS="${REPS:-3}"
BASE="${BASE:-http://localhost:8080}"
DUR="${DUR:-120s}"
DUR_S="${DUR%s}"
OUT="results/saturation.csv"
mkdir -p results
[ -s "$OUT" ] || echo "offered_rate,strategy,run,achieved_rps,error_rate,p99" > "$OUT"

# achieved_rps, error_rate, p99 from a k6 --summary-export JSON + window seconds.
summarize() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); dur = float(sys.argv[2])
m = d["metrics"]
total = m.get("op_total", {}).get("count", 0) or 0
errs = m.get("op_error", {}).get("count", 0) or 0
hrd = m.get("http_req_duration", {})          # flat in --summary-export
p99 = hrd.get("p(99)", hrd.get("p(95)", 0.0))
rps = total / dur if dur else 0.0
er = (errs / total) if total else 0.0
print(f"{rps:.3f},{er:.6f},{p99:.6f}")
PY
}

for strat in $STRATEGIES; do
  for rate in $RATES; do
    for i in $(seq 1 "$REPS"); do
      run="sat-${strat,,}-${rate}-r${i}"
      dir="results/E1S/$strat/$rate/run$i"
      mkdir -p "$dir"
      echo "==== $run (offered ${rate} req/s) ===="
      IDEM_STRATEGY="$strat" EXPERIMENT_RUN="$run" docker compose up -d --build
      scripts/wait_healthy.sh
      k6 run -e BASE="$BASE" -e RATE="$rate" -e DUR="$DUR" -e RUN="$run" \
        --summary-export "$dir/k6.json" load-tests/k6/saturation.js || true
      read -r line < <(summarize "$dir/k6.json" "$DUR_S")
      echo "$rate,$strat,run$i,$line" >> "$OUT"
      echo "  -> $line"
      docker compose down -v
    done
  done
done
echo "saturation sweep complete. Run: python3 analysis/analyze.py  (renders fig_saturation.png)"
