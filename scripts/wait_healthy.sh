#!/usr/bin/env bash
# Blocks until all three service instances report Actuator health UP (or times out).
set -euo pipefail
BASE="${BASE:-http://localhost:8080}"
DEADLINE=$(( $(date +%s) + 180 ))
echo -n "waiting for services to become healthy"
until curl -fsS "$BASE/operations/strategy" >/dev/null 2>&1; do
  echo -n "."
  [ "$(date +%s)" -gt "$DEADLINE" ] && { echo " TIMEOUT"; exit 1; }
  sleep 3
done
echo " ready ($(curl -s "$BASE/operations/strategy") strategy active)"
