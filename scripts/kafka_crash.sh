#!/usr/bin/env bash
# E6 — Kafka consumer crash / message redelivery.
# Crashes a consuming service mid-processing so its uncommitted offsets are
# redelivered on restart. With the idempotent consumer + processed_messages
# guard, redelivery must NOT produce a duplicate side effect.
#
#   scripts/kafka_crash.sh svc2 before   # SIGKILL before offset commit window
#   scripts/kafka_crash.sh svc2 after    # kill after business tx, before commit
set -euo pipefail
SVC="${1:?service e.g. svc2}"
WHEN="${2:-before}"

echo "[$WHEN] hard-killing $SVC to force Kafka redelivery ..."
# SIGKILL (not graceful) so in-flight, un-acked messages are redelivered.
docker compose kill -s SIGKILL "$SVC"
sleep 2
docker compose up -d "$SVC"
echo "restarted $SVC; observe message_redeliveries_total and v_duplicate_side_effects"
