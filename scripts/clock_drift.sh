#!/usr/bin/env bash
# E5 — Clock drift. Restarts one service container with libfaketime so its wall
# clock is offset by the requested amount, exposing TTL/lease timing assumptions
# (Strategy B). ZooKeeper (Strategy C) should be unaffected because ownership is
# session/quorum-based, not clock-based.
#
#   scripts/clock_drift.sh svc1 +0.5    # svc1 runs 500ms fast
#   scripts/clock_drift.sh svc1 reset
set -euo pipefail
SVC="${1:?service name e.g. svc1}"
OFFSET="${2:?offset seconds e.g. +0.5 or 'reset'}"

if [[ "$OFFSET" == "reset" ]]; then
  docker compose stop "$SVC"
  docker compose up -d "$SVC"
  echo "reset clock on $SVC"
  exit 0
fi

# libfaketime is installed in the image; FAKETIME applies the offset process-wide.
docker compose stop "$SVC"
FAKETIME="$OFFSET" \
  docker compose run -d --name "${SVC}-drift" \
  -e LD_PRELOAD=/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1 \
  -e FAKETIME="$OFFSET" \
  "$SVC"
echo "started $SVC with clock offset ${OFFSET}s"
