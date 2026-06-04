#!/usr/bin/env bash
# Toxiproxy fault helpers for E3 (latency) and E4 (partition).
# Requires: curl, jq. Toxiproxy admin API at $TOXI (default localhost:8474).
set -euo pipefail
TOXI="${TOXI:-http://localhost:8474}"

usage() {
  cat <<EOF
Usage:
  $0 latency <proxy> <ms> [jitter_ms]     # E3: add latency toxic
  $0 clear <proxy>                         # remove all toxics from a proxy
  $0 partition <proxy> <seconds>           # E4: disable proxy for N seconds
  $0 reset <proxy>                         # E4: reset_peer toxic (connection reset)
  $0 status                                # list proxies and toxics
proxies: postgres | redis | zookeeper | kafka
EOF
}

clear_proxy() {
  local p="$1"
  for t in $(curl -s "$TOXI/proxies/$p/toxics" | jq -r '.[].name'); do
    curl -s -X DELETE "$TOXI/proxies/$p/toxics/$t" >/dev/null
  done
  echo "cleared toxics on $p"
}

case "${1:-}" in
  latency)
    p="$2"; ms="$3"; jit="${4:-0}"
    curl -s -X POST "$TOXI/proxies/$p/toxics" \
      -d "{\"name\":\"lat\",\"type\":\"latency\",\"attributes\":{\"latency\":$ms,\"jitter\":$jit}}" >/dev/null
    echo "added ${ms}ms (+-${jit}ms) latency to $p" ;;
  clear)
    clear_proxy "$2" ;;
  partition)
    p="$2"; secs="$3"
    echo "partitioning $p for ${secs}s ..."
    curl -s -X POST "$TOXI/proxies/$p" -d '{"enabled":false}' >/dev/null
    sleep "$secs"
    curl -s -X POST "$TOXI/proxies/$p" -d '{"enabled":true}' >/dev/null
    echo "restored $p" ;;
  reset)
    p="$2"
    curl -s -X POST "$TOXI/proxies/$p/toxics" \
      -d '{"name":"rst","type":"reset_peer","attributes":{"timeout":0}}' >/dev/null
    echo "added reset_peer to $p" ;;
  status)
    curl -s "$TOXI/proxies" | jq '.' ;;
  *)
    usage; exit 1 ;;
esac
