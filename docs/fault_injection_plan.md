# Fault Injection Plan (Toxiproxy)

All dependency traffic flows `service -> toxiproxy -> dependency`. Faults are
applied by adding *toxics* to the relevant Toxiproxy proxy via its admin API
(`http://localhost:8474`). Every toxic is added at the start of a measurement
window and removed at the end, so scenarios are deterministic and repeatable.

## Proxies

| Proxy | Listen | Upstream |
|-------|--------|----------|
| postgres | 25432 | postgres:5432 |
| redis | 26379 | redis:6379 |
| zookeeper | 22181 | zookeeper:2181 |
| kafka | 29092 | kafka:29092 |

## Toxic catalogue → experiment mapping

| Experiment | Toxic type | Parameters | Targets |
|-----------|------------|-----------|---------|
| E3 Latency injection | `latency` | latency ∈ {0,25,50,100,250,500} ms; jitter ∈ {10,50,100} ms | redis, postgres, zk, kafka |
| E4 Network partition | `timeout` (toxicity 1.0) or proxy disable | duration ∈ {0.5,1,2,5,10} s | one dependency at a time |
| E4 Connection reset | `reset_peer` | timeout 0 ms | redis, zk |
| E5 Clock drift | container clock offset (libfaketime) | drift ∈ {50,100,200,500,1000} ms | one service container |
| E6 Kafka redelivery | consumer SIGKILL before/after offset commit | n/a | svc consumer |

> Clock drift is *not* a Toxiproxy toxic; it is injected by running one service
> container with `LD_PRELOAD=libfaketime` and a `FAKETIME` offset, or by
> `date -s` inside an isolated network namespace. See `scripts/clock_drift.sh`.

## Example admin-API calls (used by scripts/faults.sh)

Add 100 ms ± 50 ms latency to Redis:
```
curl -s -X POST localhost:8474/proxies/redis/toxics \
  -d '{"name":"lat","type":"latency","attributes":{"latency":100,"jitter":50}}'
```

Partition ZooKeeper for 5 s (disable then re-enable):
```
curl -s -X POST localhost:8474/proxies/zookeeper -d '{"enabled":false}'
sleep 5
curl -s -X POST localhost:8474/proxies/zookeeper -d '{"enabled":true}'
```

Remove all toxics from a proxy:
```
for t in $(curl -s localhost:8474/proxies/redis/toxics | jq -r '.[].name'); do
  curl -s -X DELETE localhost:8474/proxies/redis/toxics/$t; done
```

## Invariants checked after every faulted run

1. `SELECT * FROM v_violation_rate` — duplicate side-effect violation rate.
2. `SELECT count(*) FROM v_duplicate_side_effects` — number of violating ops.
3. Lock metrics: `stale_lock_total`, `premature_lock_expiration_total`.
4. Recovery time = time from fault clear to throughput within 5% of baseline.
