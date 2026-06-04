#!/usr/bin/env bash
# End-to-end: rebuild -> verify -> measurement grid -> analysis. Designed to run
# unattended in the background. Writes results/aggregate.csv and regenerates
# figures/tables from REAL measured data.
set -uo pipefail
cd "$(dirname "$0")/.."
log() { echo "[run_all $(date +%H:%M:%S)] $*"; }

log "rebuild jar"
mvn -q -DskipTests package 2>&1 | tail -2
log "rebuild images"
docker compose build svc1 svc2 svc3 2>&1 | grep -iE 'built|error' | tail -3

# ---- boot sanity check on DB strategy ----
log "boot check (DB)"
IDEM_STRATEGY=DB EXPERIMENT_RUN=bootcheck docker compose down -v >/dev/null 2>&1
IDEM_STRATEGY=DB EXPERIMENT_RUN=bootcheck docker compose up -d >/dev/null 2>&1
d=$(( $(date +%s) + 200 ))
until curl -fsS http://localhost:8080/operations/strategy >/dev/null 2>&1; do
  [ "$(date +%s)" -gt "$d" ] && { log "BOOT FAILED"; docker compose logs svc1 --tail 30; exit 1; }
  sleep 3
done
B='{"idempotencyKey":"boot1","operationType":"PAYMENT","entityId":"e","userId":"u","amount":1.00,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"boot"}'
c1=$(curl -s -o /dev/null -w '%{http_code}' -XPOST localhost:8080/operations -H 'Content-Type: application/json' -d "$B")
c2=$(curl -s -o /dev/null -w '%{http_code}' -XPOST localhost:8080/operations -H 'Content-Type: application/json' -d "$B")
se=$(docker compose exec -T postgres psql -U idem -d idemstudy -At -c "SELECT count(*) FROM operation_side_effects WHERE idempotency_key='boot1';" 2>/dev/null | grep -v warning)
log "boot check: first=$c1 second=$c2 side_effects=$se (expect 201/200/1)"
[ "$se" = "1" ] || { log "BOOT CHECK CORRECTNESS FAILED"; exit 1; }

# ---- run the measurement grid ----
log "starting measurement grid"
STRATS_PERF="DB REDIS ZK KAFKA" REPS=2 bash scripts/smoke_grid.sh
log "grid finished"

# ---- analysis on REAL data ----
log "analysis"
python3 analysis/analyze.py 2>&1 | tail -15
log "ALL DONE"
