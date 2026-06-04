#!/usr/bin/env bash
# =============================================================================
# run_campaign.sh — Full right-sized measurement campaign (single command).
#
# Produces results/aggregate.csv + results/saturation.csv from LIVE runs, then
# regenerates all figures/tables and (if a LaTeX toolchain is present) the PDF.
#
# Right-sized parameters (per the operator's request, tuned for this host):
#   - Measurement window : 60s        (WINDOW)
#   - Warm-up            : 60s        (WARMUP, once per strategy stack)
#   - Repetitions        : 3 per cell (REPS) — minimum for a Student-t CI
#   - Saturation grid    : tuned to THIS host (DB knee measured ~800-1000 r/s),
#                          not the 10k projection target          (SAT_RATES)
#   - Order              : E1, E2, E3 first (priority), then E4, E5, E6, E7
#
# Execution model — SERIAL on purpose (read this before "parallelizing"):
#   The operator asked to parallelize strategies on disjoint dependencies. We do
#   NOT generate concurrent load, because the overriding requirement is
#   "statistical validity for IEEE Access": throughput and p99 are the headline
#   CW2/CW3 deliverables, and two load generators sharing this host's CPUs/run-
#   queue inflate each other's tail latency and cap each other's throughput —
#   exactly the load-path artifact CW2 exists to remove. RAM was never the limit
#   (stack ~2.5 GB on 31 GB); measurement isolation is. We therefore (a) build all
#   images once up front, (b) boot ONE stack per strategy and run every Phase-1
#   scenario against it (no reboot between scenarios/reps — the big speed-up), and
#   (c) keep each measured cell alone on the box. Correctness metrics (DSEVR,
#   redeliveries, conflict accuracy) are categorical and would survive contention,
#   but recovery_s (E4) and premature-expiration timing (E5) would not, so the
#   whole campaign stays serial for one consistent, defensible methodology.
#
# Everything is logged with timestamps to results/campaign_run.log. The script
# never aborts on a single failed cell (set -u, no -e); it logs and continues.
#
#   bash scripts/run_campaign.sh           # run it
#   REPS=5 WINDOW=900 bash scripts/run_campaign.sh   # e.g. publication scale
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# ----------------------------- configuration --------------------------------
STRATS_ALL="${STRATS_ALL:-DB REDIS ZK KAFKA OUTBOX PAYLOAD_HASH}"
REPS="${REPS:-3}"
WARMUP="${WARMUP:-60}"
WINDOW="${WINDOW:-60}"
E1_RATE="${E1_RATE:-200}"                       # baseline offered load (sub-knee, clean p99)
SAT_RATES="${SAT_RATES:-100 200 400 600 800 1000 1500}"
SAT_DUR="${SAT_DUR:-20}"                         # short window suffices for the knee
LAT_LEVELS="${LAT_LEVELS:-0 25 50 100 250 500}"
E3_RATE="${E3_RATE:-200}"
E3_DUR="${E3_DUR:-40}"
E3_NKEYS="${E3_NKEYS:-50}"
PART_SECS="${PART_SECS:-8}"
E2_BURST="${E2_BURST:-50}"
E2_OPS="${E2_OPS:-200}"

NET="idemstudy_default"
K6="grafana/k6:0.52.0"
CF="-f docker-compose.yml -f docker-compose.override.yml"
DRIFT="$CF -f docker-compose.clockdrift.yml"
RAW="results/raw";        mkdir -p "$RAW"
CKPT="results/checkpoints"; mkdir -p "$CKPT"
AGG="results/aggregate.csv"
SAT="results/saturation.csv"
LOG="results/campaign_run.log"
TREND="avg,min,med,p(90),p(95),p(99),max"

# ----------------------------- logging --------------------------------------
exec > >(tee -a "$LOG") 2>&1
log() { echo "[campaign $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
hr()  { echo "----------------------------------------------------------------"; }

# ----------------------------- helpers --------------------------------------
P()    { docker compose $CF exec -T postgres psql -U idem -d idemstudy -At "$@" 2>/dev/null | grep -vi warning; }
prom() { curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null; }
jqv()  { jq -r "$2 // 0" "$1" 2>/dev/null; }
dep_for(){ case "$1" in REDIS) echo redis;; ZK) echo zookeeper;; KAFKA) echo kafka;; *) echo postgres;; esac; }
secs_since(){ awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }

# k6run <script> <tag> [extra -e env...] -> echoes RAW/<tag>.json
k6run() {
  local script="$1" tag="$2"; shift 2
  docker run --rm --network "$NET" --user "$(id -u):$(id -g)" "$@" \
    -e BASE=http://nginx:8080 -e RUN="$tag" \
    -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" \
    "$K6" run --quiet --summary-trend-stats="$TREND" \
    --summary-export "/out/${tag}.json" "/k6/${script}" >/dev/null 2>&1 || true
  echo "$RAW/${tag}.json"
}

wait_up() {  # wait for the 3 JVMs behind nginx
  local d=$(( $(date +%s) + 240 ))
  until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do
    [ "$(date +%s)" -gt "$d" ] && { log "  TIMEOUT waiting for stack"; return 1; }
    sleep 3
  done
}

# upS <strategy> [compose-args] [VAR=val ...extra env prefix passed before compose]
upS() {
  local S="$1"; local cfargs="${2:-$CF}"; shift 2 || true
  IDEM_STRATEGY="$S" EXPERIMENT_RUN="camp-$S" "$@" docker compose $cfargs down -v >/dev/null 2>&1
  IDEM_STRATEGY="$S" EXPERIMENT_RUN="camp-$S" "$@" docker compose $cfargs up -d >/dev/null 2>&1
  wait_up
}

downS() { docker compose $CF down -v >/dev/null 2>&1 || true; }

checkpoint() {  # <label>
  cp "$AGG" "$CKPT/aggregate.$1.csv" 2>/dev/null || true
  log "  checkpoint saved: $CKPT/aggregate.$1.csv ($(wc -l < "$AGG") rows)"
}

# DSEVR scoped to a key prefix; echoes "logical viol vrate"
dsevr_scoped() {  # <key_like>
  local like="$1" logical viol
  logical=$(P -c "SELECT count(DISTINCT operation_id) FROM operation_side_effects WHERE idempotency_key LIKE '$like';")
  viol=$(P -c "SELECT count(*) FROM (SELECT operation_id FROM operation_side_effects WHERE idempotency_key LIKE '$like' GROUP BY operation_id HAVING count(*)>1) t;")
  logical=${logical:-0}; viol=${viol:-0}
  awk -v v="$viol" -v l="$logical" 'BEGIN{printf "%s %s %.6f", l, v, (l>0)?v/l:0}'
}

drain_consumer() {  # wait until processed_messages count stabilises (async strategies)
  local prev=-1 stable=0 dl=$(( $(date +%s)+180 )) c
  while [ "$(date +%s)" -lt "$dl" ]; do
    c=$(P -c "SELECT count(*) FROM processed_messages;"); c=${c:-0}
    if [ "$c" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge 3 ] && break; prev=$c; sleep 3
  done
}

# ============================ preflight =====================================
START_TS=$(date +%s)
hr; log "CAMPAIGN START"
log "config: REPS=$REPS WARMUP=${WARMUP}s WINDOW=${WINDOW}s E1_RATE=$E1_RATE"
log "config: SAT_RATES='$SAT_RATES' (SAT_DUR=${SAT_DUR}s)  LAT_LEVELS='$LAT_LEVELS'"
log "config: strategies='$STRATS_ALL'"
log "host: $(nproc) cores, $(free -g | awk '/Mem:/{print $2}')GB RAM, docker $(docker version --format '{{.Server.Version}}')"
hr

log "ensuring prebuilt jar exists (Dockerfile.jar)"
if [ ! -f target/idempotent-operation-service-1.0.0.jar ]; then
  log "  jar missing -> mvn -q -DskipTests package"
  mvn -q -DskipTests package || { log "FATAL: maven build failed"; exit 1; }
fi
log "pulling k6 image"; docker pull "$K6" >/dev/null 2>&1 || true
log "building service images once"
docker compose $CF build svc1 svc2 svc3 2>&1 | grep -iE 'built|error' | tail -3

# Back up any prior (pilot) aggregate, then start a fresh real campaign file.
if [ -f "$AGG" ]; then cp "$AGG" "results/aggregate.pilot-backup.csv"; log "backed up prior aggregate -> results/aggregate.pilot-backup.csv"; fi
echo "scenario,strategy,run,metric,value" > "$AGG"
echo "offered_rate,strategy,run,achieved_rps,error_rate,p99" > "$SAT"

# boot sanity on DB
log "boot sanity check (DB)"
if upS DB "$CF"; then
  B='{"idempotencyKey":"camp-boot","operationType":"PAYMENT","entityId":"e","userId":"u","amount":1.00,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"boot"}'
  c1=$(curl -s -o /dev/null -w '%{http_code}' -XPOST localhost:8080/operations -H 'Content-Type: application/json' -d "$B")
  c2=$(curl -s -o /dev/null -w '%{http_code}' -XPOST localhost:8080/operations -H 'Content-Type: application/json' -d "$B")
  se=$(P -c "SELECT count(*) FROM operation_side_effects WHERE idempotency_key='camp-boot';")
  log "  boot check: first=$c1 second=$c2 side_effects=$se (expect 201/200/1)"
  [ "${se:-0}" = "1" ] || log "  WARNING: boot correctness unexpected (continuing)"
  downS
else
  log "FATAL: stack did not become healthy on boot sanity check"; exit 1
fi

# ===================== PHASE 1: E1, E2, E3 (priority) =======================
hr; log "PHASE 1 — E1 (baseline + saturation), E2 (burst DSEVR), E3 (latency sweep)"
for S in $STRATS_ALL; do
  hr; log "STRATEGY $S — booting one stack for all Phase-1 scenarios"
  if ! upS "$S" "$CF"; then log "  skip $S (boot timeout)"; downS; continue; fi
  dep=$(dep_for "$S")
  log "  active=$(curl -s http://localhost:8080/operations/strategy) dep=$dep"

  # ---- warm-up (discarded) ----
  log "  warm-up ${WARMUP}s at ${E1_RATE} r/s"
  k6run saturation.js "warm-$S" -e RATE="$E1_RATE" -e DUR="${WARMUP}s" >/dev/null

  # ---- E1 baseline: REPS x WINDOW at fixed sub-knee rate ----
  for i in $(seq 1 "$REPS"); do
    f=$(k6run saturation.js "e1-$S-run$i" -e RATE="$E1_RATE" -e DUR="${WINDOW}s")
    thr=$(jqv "$f" '.metrics.http_reqs.rate'); p99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]'); p95=$(jqv "$f" '.metrics.http_req_duration["p(95)"]')
    { echo "E1,$S,run$i,throughput,$thr"; echo "E1,$S,run$i,p99,$p99"; echo "E1,$S,run$i,p95,$p95"; } >> "$AGG"
    log "    E1 run$i: thr=${thr} r/s p99=${p99}ms"
  done

  # ---- E1 saturation sweep (CW2): open-loop knee -> saturation.csv ----
  log "  saturation sweep: $SAT_RATES (x$REPS, ${SAT_DUR}s)"
  for rate in $SAT_RATES; do
    for i in $(seq 1 "$REPS"); do
      f=$(k6run saturation.js "sat-$S-$rate-r$i" -e RATE="$rate" -e DUR="${SAT_DUR}s")
      tot=$(jqv "$f" '.metrics.op_total.count'); er=$(jqv "$f" '.metrics.op_error.count')
      p99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]')
      line=$(awk -v t="$tot" -v e="$er" -v d="$SAT_DUR" -v p="$p99" 'BEGIN{printf "%.3f,%.6f,%.6f", (d>0)?t/d:0, (t>0)?e/t:0, p}')
      echo "$rate,$S,run$i,$line" >> "$SAT"
    done
    log "    rate=${rate}: $(awk -F, -v r="$rate" -v s="$S" '$1==r&&$2==s{n++;rps+=$4;er+=$5} END{if(n)printf "achieved=%.0f r/s err=%.1f%%",rps/n,100*er/n}' "$SAT")"
  done

  # ---- E2 duplicate burst (DSEVR), REPS, key-scoped per rep ----
  for i in $(seq 1 "$REPS"); do
    tag="e2-$S-r$i"
    f=$(k6run duplicate-burst.js "$tag" -e BURST="$E2_BURST" -e OPS="$E2_OPS")
    case "$S" in KAFKA|OUTBOX) drain_consumer ;; *) sleep 3 ;; esac
    read -r logical viol vrate <<<"$(dsevr_scoped "${tag}-op-%")"
    total=$(P -c "SELECT count(*) FROM operation_side_effects WHERE idempotency_key LIKE '${tag}-op-%';"); total=${total:-0}
    bp99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]')
    { echo "E2,$S,run$i,violation_rate,$vrate"; echo "E2,$S,run$i,p99,$bp99"
      echo "E2,$S,run$i,side_effects_total,$total"; echo "E2,$S,run$i,logical_ops,$logical"; } >> "$AGG"
    log "    E2 run$i: logical=$logical total=$total viol=$viol DSEVR=$vrate"
  done

  # ---- E3 latency sweep (CW3): LAT_LEVELS x REPS on this strategy's dep ----
  log "  E3 latency sweep on $dep: $LAT_LEVELS ms (x$REPS)"
  for lat in $LAT_LEVELS; do
    scripts/faults.sh clear "$dep" >/dev/null 2>&1 || true
    [ "$lat" -gt 0 ] && scripts/faults.sh latency "$dep" "$lat" 20 >/dev/null 2>&1
    for i in $(seq 1 "$REPS"); do
      tag="e3-$S-lat$lat-r$i"
      f=$(k6run fault_load.js "$tag" -e RATE="$E3_RATE" -e DUR="${E3_DUR}s" -e NKEYS="$E3_NKEYS")
      p99=$(jqv "$f" '.metrics.http_req_duration["p(99)"]')
      read -r l3 v3 vr3 <<<"$(dsevr_scoped "flt-${tag}-%")"
      { echo "E3,$S,lat${lat}-r$i,p99,$p99"; echo "E3,$S,lat${lat}-r$i,violation_rate,$vr3"; } >> "$AGG"
    done
    log "    lat=${lat}ms done"
    scripts/faults.sh clear "$dep" >/dev/null 2>&1 || true
  done

  checkpoint "phase1-$S"
  downS
done

# ===================== PHASE 2: E4, E5, E6, E7 ==============================
hr; log "PHASE 2 — E4 partition, E5 clock-drift, E6 Kafka crash, E7 conflict"

# ---- E4 network partition ----
for S in DB REDIS ZK; do
  dep=$(dep_for "$S")
  for i in $(seq 1 "$REPS"); do
    tag="e4-$S-r$i"
    log "  E4 $S run$i (partition $dep ${PART_SECS}s)"
    if ! upS "$S" "$CF"; then log "    skip"; downS; continue; fi
    f="$RAW/$tag.json"
    docker run --rm --network "$NET" --user "$(id -u):$(id -g)" \
      -e BASE=http://nginx:8080 -e RUN="$tag" -e RATE=250 -e DUR=60s -e NKEYS=50 \
      -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" "$K6" \
      run --quiet --summary-trend-stats="$TREND" --summary-export "/out/$tag.json" /k6/fault_load.js >/dev/null 2>&1 &
    K6PID=$!
    sleep 20
    scripts/faults.sh partition "$dep" "$PART_SECS" >/dev/null 2>&1
    rec_start=$(date +%s.%N)
    REQ='{"idempotencyKey":"rec-'$tag'","operationType":"PAYMENT","entityId":"e","userId":"u","amount":1,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"rec"}'
    while true; do
      curl -fsS -o /dev/null -X POST http://localhost:8080/operations -H 'Content-Type: application/json' -d "$REQ" 2>/dev/null && break
      [ "$(awk -v a="$rec_start" -v b="$(date +%s.%N)" 'BEGIN{print (b-a>30)?1:0}')" = 1 ] && break
      sleep 0.2
    done
    rec=$(secs_since "$rec_start"); wait $K6PID 2>/dev/null || true
    rej=$(jqv "$f" '.metrics.op_rejected.count'); err=$(jqv "$f" '.metrics.op_error.count'); reqs=$(jqv "$f" '.metrics.http_reqs.count')
    errrate=$(awk -v e="$err" -v r="$rej" -v t="$reqs" 'BEGIN{print (t>0)?(e+r)/t:0}')
    read -r logical viol vrate <<<"$(dsevr_scoped "flt-${tag}-%")"
    { echo "E4,$S,run$i,violation_rate,$vrate"; echo "E4,$S,run$i,error_rate,$errrate"
      echo "E4,$S,run$i,recovery_s,$rec"; echo "E4,$S,run$i,logical_ops,$logical"; } >> "$AGG"
    log "    E4 $S run$i: DSEVR=$vrate err=$errrate recovery=${rec}s"
    downS
  done
done
checkpoint "phase2-E4"

# ---- E5 clock drift & timing stress ----
for i in $(seq 1 "$REPS"); do
  # REDIS +2s client drift
  log "  E5 REDIS +2s drift run$i"
  if IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redis-r$i FAKETIME=+2 docker compose $DRIFT down -v >/dev/null 2>&1; \
     IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redis-r$i FAKETIME=+2 docker compose $DRIFT up -d >/dev/null 2>&1; wait_up; then
    k6run fault_load.js "d-REDIS-r$i" -e RATE=250 -e DUR=50s -e NKEYS=40 >/dev/null; sleep 3
    prem=$(prom 'sum(premature_lock_expiration_total)'); stale=$(prom 'sum(stale_lock_total)'); to=$(prom 'sum(lock_timeout_total)')
    read -r l v vr <<<"$(dsevr_scoped "flt-d-REDIS-r$i-%")"
    { echo "E5,REDIS,run$i,premature_expirations,${prem:-0}"; echo "E5,REDIS,run$i,stale_locks,${stale:-0}"
      echo "E5,REDIS,run$i,lock_timeouts,${to:-0}"; echo "E5,REDIS,run$i,violation_rate,$vr"; echo "E5,REDIS,run$i,logical_ops,$l"; } >> "$AGG"
    log "    E5 REDIS run$i: premature=${prem:-0} DSEVR=$vr"
  fi
  docker compose $DRIFT down -v >/dev/null 2>&1 || true

  # ZK +2s client drift (control)
  log "  E5 ZK +2s drift run$i"
  if IDEM_STRATEGY=ZK EXPERIMENT_RUN=e5-zk-r$i FAKETIME=+2 docker compose $DRIFT down -v >/dev/null 2>&1; \
     IDEM_STRATEGY=ZK EXPERIMENT_RUN=e5-zk-r$i FAKETIME=+2 docker compose $DRIFT up -d >/dev/null 2>&1; wait_up; then
    k6run fault_load.js "d-ZK-r$i" -e RATE=250 -e DUR=50s -e NKEYS=40 >/dev/null; sleep 3
    prem=$(prom 'sum(premature_lock_expiration_total)'); stale=$(prom 'sum(stale_lock_total)'); to=$(prom 'sum(lock_timeout_total)')
    read -r l v vr <<<"$(dsevr_scoped "flt-d-ZK-r$i-%")"
    { echo "E5,ZK,run$i,premature_expirations,${prem:-0}"; echo "E5,ZK,run$i,stale_locks,${stale:-0}"
      echo "E5,ZK,run$i,lock_timeouts,${to:-0}"; echo "E5,ZK,run$i,violation_rate,$vr"; echo "E5,ZK,run$i,logical_ops,$l"; } >> "$AGG"
    log "    E5 ZK run$i: premature=${prem:-0} DSEVR=$vr"
  fi
  docker compose $DRIFT down -v >/dev/null 2>&1 || true

  # REDIS_TS timing stress: short lease (300ms) + 200ms Redis latency
  log "  E5 REDIS_TS timing-stress run$i"
  if IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redists-r$i IDEM_LOCK_LEASE_MS=300 IDEM_LOCK_WAIT_MS=3000 docker compose $CF down -v >/dev/null 2>&1; \
     IDEM_STRATEGY=REDIS EXPERIMENT_RUN=e5-redists-r$i IDEM_LOCK_LEASE_MS=300 IDEM_LOCK_WAIT_MS=3000 docker compose $CF up -d >/dev/null 2>&1; wait_up; then
    scripts/faults.sh latency redis 200 50 >/dev/null 2>&1
    k6run fault_load.js "d-REDISTS-r$i" -e RATE=250 -e DUR=50s -e NKEYS=40 >/dev/null
    scripts/faults.sh clear redis >/dev/null 2>&1; sleep 3
    prem=$(prom 'sum(premature_lock_expiration_total)'); stale=$(prom 'sum(stale_lock_total)'); to=$(prom 'sum(lock_timeout_total)')
    read -r l v vr <<<"$(dsevr_scoped "flt-d-REDISTS-r$i-%")"
    { echo "E5,REDIS_TS,run$i,premature_expirations,${prem:-0}"; echo "E5,REDIS_TS,run$i,stale_locks,${stale:-0}"
      echo "E5,REDIS_TS,run$i,lock_timeouts,${to:-0}"; echo "E5,REDIS_TS,run$i,violation_rate,$vr"; echo "E5,REDIS_TS,run$i,logical_ops,$l"; } >> "$AGG"
    log "    E5 REDIS_TS run$i: premature=${prem:-0} DSEVR=$vr"
  fi
  docker compose $CF down -v >/dev/null 2>&1 || true
done
checkpoint "phase2-E5"

# ---- E6 Kafka consumer crash / redelivery ----
for i in $(seq 1 "$REPS"); do
  tag="e6-r$i"
  log "  E6 KAFKA crash run$i"
  if upS KAFKA "$CF"; then
    docker run --rm --network "$NET" --user "$(id -u):$(id -g)" \
      -e BASE=http://nginx:8080 -e RUN="$tag" -e RATE=200 -e DUR=45s -e NKEYS=300 \
      -v "$PWD/load-tests/k6:/k6:ro" -v "$PWD/$RAW:/out" "$K6" \
      run --quiet --summary-export "/out/$tag.json" /k6/fault_load.js >/dev/null 2>&1 &
    K6PID=$!
    sleep 12; log "    SIGKILL svc2 (mid-processing)"; docker compose $CF kill -s SIGKILL svc2 >/dev/null 2>&1
    sleep 3; docker compose $CF up -d svc2 >/dev/null 2>&1
    wait $K6PID 2>/dev/null || true
    drain_consumer
    redel=$(prom 'sum(message_redeliveries_total)'); dupsupp=$(prom 'sum(idempotency_duplicates_total)')
    read -r logical viol vrate <<<"$(dsevr_scoped "flt-${tag}-%")"
    { echo "E6,KAFKA,run$i,violation_rate,$vrate"; echo "E6,KAFKA,run$i,redeliveries,${redel:-0}"
      echo "E6,KAFKA,run$i,duplicates_suppressed,${dupsupp:-0}"; echo "E6,KAFKA,run$i,logical_ops,$logical"; } >> "$AGG"
    log "    E6 run$i: redeliveries=${redel:-0} suppressed=${dupsupp:-0} DSEVR=$vrate"
    downS
  else log "    skip E6 run$i"; downS; fi
done
checkpoint "phase2-E6"

# ---- E7 conflicting payload ----
for S in PAYLOAD_HASH DB; do
  for i in $(seq 1 "$REPS"); do
    tag="e7-$S-r$i"
    log "  E7 $S run$i"
    if upS "$S" "$CF"; then
      f=$(k6run conflict.js "$tag")
      cc=$(jqv "$f" '.metrics.correct_conflict.count'); ir=$(jqv "$f" '.metrics.incorrect_replay.count'); fa=$(jqv "$f" '.metrics.first_applied.count')
      acc=$(awk -v c="$cc" -v i2="$ir" 'BEGIN{d=c+i2; print (d>0)?c/d:0}')
      { echo "E7,$S,run$i,conflict_accuracy,$acc"; echo "E7,$S,run$i,correct_conflict,$cc"
        echo "E7,$S,run$i,incorrect_replay,$ir"; echo "E7,$S,run$i,first_applied,$fa"; } >> "$AGG"
      log "    E7 $S run$i: correct=$cc incorrect=$ir accuracy=$acc"
      downS
    else log "    skip"; downS; fi
  done
done
checkpoint "phase2-E7"

# ============================ analysis + paper ==============================
hr; log "ANALYSIS — regenerating figures and tables from measured data"
python3 analysis/analyze.py 2>&1 | tail -12
python3 analysis/make_results_table.py 2>&1 | tail -3

log "PAPER — rebuilding PDF"
if command -v pdflatex >/dev/null 2>&1; then
  ( cd paper && make ) 2>&1 | tail -8 && log "  paper built: paper/main.pdf"
else
  log "  SKIP: no LaTeX toolchain (pdflatex) on this host. Build the PDF with"
  log "        'cd paper && make' after 'sudo apt-get install -y texlive-latex-recommended texlive-publishers texlive-fonts-recommended', or on Overleaf."
fi

# ============================ summary =======================================
END_TS=$(date +%s); MINS=$(( (END_TS-START_TS)/60 ))
hr; log "CAMPAIGN COMPLETE in ${MINS} min"
log "rows per scenario in $AGG:"
awk -F, 'NR>1{c[$1]++} END{for(s in c) printf "    %s: %d rows\n", s, c[s]}' "$AGG" | sort
log "saturation knee (first rate with mean error >=1%) per strategy:"
awk -F, 'NR>1{n[$2","$1]++; rps[$2","$1]+=$4; er[$2","$1]+=$5}
  END{for(k in n){split(k,a,","); strat=a[1]; rate=a[2]+0;
      mer=er[k]/n[k]; mrps=rps[k]/n[k];
      if(mer>=0.01 && (!(strat in kneerate) || rate<kneerate[strat])){knee[strat]=mrps; kneerate[strat]=rate}}
      for(s in knee) printf "    %s: knee ~%d r/s (first >=1%% error at offered %d)\n", s, knee[s], kneerate[s]}' "$SAT" | sort
log "figures in results/figures/ ; tables in results/tables/ ; full log: $LOG"
hr
