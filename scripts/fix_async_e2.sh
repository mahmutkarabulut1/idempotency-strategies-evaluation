#!/usr/bin/env bash
# Clean E2 re-measurement for strategies whose first pass had a bad denominator:
#   - OUTBOX/KAFKA (async): drain detector now requires a NON-ZERO processed count
#     before accepting stability (the old one fired at 0).
#   - PAYLOAD_HASH (sync): fresh stack, burst only, count immediately.
# Uses underscore-free run tags (so SQL LIKE '_' wildcards can't widen the scope)
# and a fresh stack per strategy (so no E1 residue). Updates E2,<S> rows in aggregate.csv.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
CF="-f docker-compose.yml -f docker-compose.override.yml"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }
wait_up(){ local d=$(( $(date +%s)+220 )); until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do [ "$(date +%s)" -gt "$d" ] && return 1; sleep 3; done; }

# tag has no underscore; map strategy -> tag
tag_for(){ case "$1" in OUTBOX) echo e2cOUTBOX;; KAFKA) echo e2cKAFKA;; PAYLOAD_HASH) echo e2cPH;; *) echo e2cX;; esac; }
is_async(){ case "$1" in OUTBOX|KAFKA) return 0;; *) return 1;; esac; }

for S in "$@"; do
  tag=$(tag_for "$S")
  echo "==== clean E2 re-measure: $S (tag=$tag) ===="
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e2c-$S docker compose $CF down -v >/dev/null 2>&1
  IDEM_STRATEGY=$S EXPERIMENT_RUN=e2c-$S docker compose $CF up -d >/dev/null 2>&1
  wait_up || { echo "  skip $S"; continue; }
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN=$tag -e BURST=50 -e OPS=200 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-trend-stats="avg,p(95),p(99),max" \
    --summary-export /out/$tag.json /k6/duplicate-burst.js >/dev/null 2>&1

  if is_async "$S"; then
    prev=-1; stable=0; seen=0; dl=$(( $(date +%s)+240 ))
    while [ "$(date +%s)" -lt "$dl" ]; do
      c=$(P -c "SELECT count(*) FROM processed_messages;"); c=${c:-0}
      [ "$c" -gt 0 ] && seen=1
      if [ "$c" = "$prev" ] && [ "$seen" = 1 ]; then stable=$((stable+1)); else stable=0; fi
      [ "$stable" -ge 4 ] && break
      prev=$c; sleep 3
    done
    echo "  drained at processed=$prev (seen=$seen)"
  else
    sleep 3
  fi

  logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE '$tag-op-%';")
  total=$(P -c   "SELECT count(*) FROM operation_side_effects WHERE idempotency_key LIKE '$tag-op-%';")
  viol=$(P -c    "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE '$tag-op-%' GROUP BY operation_id HAVING count(*)>1) t;")
  p99=$(jq -r '.metrics.http_req_duration["p(99)"] // 0' "$RAW/$tag.json" 2>/dev/null)
  logical=${logical:-0}; total=${total:-0}; viol=${viol:-0}
  rate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{print (l>0)?v/l:0}')
  grep -v "^E2,$S," "$AGG" > "$AGG.t"; mv "$AGG.t" "$AGG"
  { echo "E2,$S,run1,violation_rate,$rate"; echo "E2,$S,run1,p99,$p99"
    echo "E2,$S,run1,side_effects_total,$total"; echo "E2,$S,run1,logical_ops,$logical"; } >> "$AGG"
  echo "  E2 $S CLEAN: logical=$logical total=$total viol=$viol rate=$rate"
done
echo "==== clean E2 re-measure done ===="
