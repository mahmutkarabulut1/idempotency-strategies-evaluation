#!/usr/bin/env bash
# E5 — Clock drift & lock-timing stress. Three runs:
#   REDIS      : svc1 wall clock skewed +2s (libfaketime), normal lease.
#   ZK         : svc1 wall clock skewed +2s, session-based lock (control).
#   REDIS_TS   : short lease (300ms) + injected Redis latency (200ms) so the lease
#                can expire mid critical-section -> premature expiration (H2).
# Measures DSEVR (scoped), premature_lock_expiration_total, stale_lock_total,
# lock_timeout_total (from Prometheus). Appends E5,* rows to aggregate.csv.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=idemstudy_default; K6=grafana/k6:0.52.0; RAW=results/raw; AGG=results/aggregate.csv
CF="-f docker-compose.yml -f docker-compose.override.yml"
DRIFT="$CF -f docker-compose.clockdrift.yml"
P(){ docker compose exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -v warning; }
prom(){ curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null; }
wait_up(){ local d=$(( $(date +%s)+220 )); until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do [ "$(date +%s)" -gt "$d" ] && return 1; sleep 3; done; }

[ -f "$AGG" ] && { grep -v '^E5,' "$AGG" > "$AGG.tmp"; mv "$AGG.tmp" "$AGG"; }

run_load(){ # <runtag>
  docker run --rm --network $NET --user "$(id -u):$(id -g)" \
    -e BASE=http://nginx:8080 -e RUN="$1" -e RATE=250 -e DUR=50s -e NKEYS=40 \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" $K6 \
    run --quiet --summary-export "/out/$1.json" /k6/fault_load.js >/dev/null 2>&1
}

record(){ # <label> <runtag>
  local label="$1" tag="$2"
  local prem stale to logical viol vrate
  prem=$(prom 'sum(premature_lock_expiration_total)'); stale=$(prom 'sum(stale_lock_total)')
  to=$(prom 'sum(lock_timeout_total)')
  logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE 'flt-$tag-%';")
  viol=$(P -c "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE 'flt-$tag-%' GROUP BY operation_id HAVING count(*)>1) t;")
  logical=${logical:-0}; viol=${viol:-0}; prem=${prem:-0}; stale=${stale:-0}; to=${to:-0}
  vrate=$(awk -v v="$viol" -v l="$logical" 'BEGIN{print (l>0)?v/l:0}')
  { echo "E5,$label,run1,premature_expirations,$prem"
    echo "E5,$label,run1,stale_locks,$stale"
    echo "E5,$label,run1,lock_timeouts,$to"
    echo "E5,$label,run1,violation_rate,$vrate"
    echo "E5,$label,run1,logical_ops,$logical"; } >> "$AGG"
  printf "  E5 %s: premature=%s stale=%s timeouts=%s logical=%s viol=%s vrate=%s\n" \
    "$label" "$prem" "$stale" "$to" "$logical" "$viol" "$vrate"
}

# ---- 1) REDIS with +2s clock drift on svc1 ----
echo "==== E5 clock-drift: REDIS (svc1 +2s) ===="
IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redis FAKETIME=+2 docker compose $DRIFT down -v >/dev/null 2>&1
IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redis FAKETIME=+2 docker compose $DRIFT up -d >/dev/null 2>&1
if wait_up; then echo "  svc1 date: $(docker compose $DRIFT exec -T svc1 date +%s 2>/dev/null) host: $(date +%s)"; run_load d-REDIS; sleep 3; record REDIS d-REDIS; else echo "  skip"; fi

# ---- 2) ZK with +2s clock drift on svc1 (control: session-based) ----
echo "==== E5 clock-drift: ZK (svc1 +2s) ===="
IDEM_STRATEGY=ZK EXPERIMENT_RUN=e5-zk FAKETIME=+2 docker compose $DRIFT down -v >/dev/null 2>&1
IDEM_STRATEGY=ZK EXPERIMENT_RUN=e5-zk FAKETIME=+2 docker compose $DRIFT up -d >/dev/null 2>&1
if wait_up; then run_load d-ZK; sleep 3; record ZK d-ZK; else echo "  skip"; fi

# ---- 3) REDIS timing stress: short lease + Redis latency ----
echo "==== E5 timing-stress: REDIS_TS (lease=300ms + 200ms Redis latency) ===="
IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redists IDEM_LOCK_LEASE_MS=300 IDEM_LOCK_WAIT_MS=3000 \
  docker compose $CF down -v >/dev/null 2>&1
IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redists IDEM_LOCK_LEASE_MS=300 IDEM_LOCK_WAIT_MS=3000 \
  docker compose $CF up -d >/dev/null 2>&1
if wait_up; then
  scripts/faults.sh latency redis 200 50 >/dev/null 2>&1
  run_load d-REDISTS
  scripts/faults.sh clear redis >/dev/null 2>&1
  sleep 3; record REDIS_TS d-REDISTS
else echo "  skip"; fi
echo "==== E5 done ===="
