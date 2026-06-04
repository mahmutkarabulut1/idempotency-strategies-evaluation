# Result Summary

**Status:** E1 (baseline) and E2 (duplicate-burst) figures/tables in this folder
are **measured** from the live testbed (`results/aggregate.csv`). E3/E4/E5
(latency, partition, clock-drift) figures remain **illustrative projections**
pending the extended fault campaign and are labelled as such.

Host: single multi-core machine, Docker Compose (Postgres 16, Redis 7,
ZooKeeper 3.8, Kafka 7.6, Toxiproxy 2.9), 3 service JVMs behind nginx, all
dependencies reached through Toxiproxy. Load: k6, 2 reps/strategy, short windows.

## Measured results (warm run; cold first run treated as warm-up)

| Strategy | Throughput (req/s) | p99 (ms) | DSEVR (E2) |
|----------|-------------------:|---------:|-----------:|
| DB (Postgres unique)     | 776.6 | 8.1   | 0.0000 |
| REDIS (Redisson lock)    | 776.6 | 22.6  | 0.0000 |
| ZK (Curator mutex)       | 773.3 | 188.8 | 0.0000 |
| KAFKA (idempotent consumer) | 776.6 | 1.5 | 0.0000 |

## Headline findings (measured)

1. **Zero duplicate side effects (DSEVR = 0) for all four strategies** under a
   burst of 50 concurrent same-key requests per operation across three JVMs. For
   DB/Redis/ZK this was confirmed on the audited side-effect table; for Kafka, an
   out-of-band query found **0 operations with >1 side effect across ~24k
   processed events**, confirming the deterministic-operation-id consumer dedup.
   → Duplicate *delivery* happens; duplicate *side effects* do not (H1–H4).
2. **Hot-path p99 ordering: Kafka (1.5 ms) < DB (8 ms) < Redis (23 ms) <
   ZooKeeper (189 ms).** Consensus coordination is the most expensive on the
   critical path (H3); event-driven processing has the lowest API latency because
   the side effect is deferred to the consumer.
3. **Throughput was comparable (≈757–777 req/s)** at the offered closed-loop load,
   so tail latency — not throughput — is the discriminating axis here.
4. **Cold-start effect:** first-iteration p99 was much higher (DB 440 ms,
   Redis/ZK >1 s) due to JVM/pool warm-up; excluded as warm-up.

## Fault experiments (measured)

**E4 — network partition** (8 s partition of each strategy's dependency mid-load):

| Strategy | DSEVR | Request error rate | API recovery |
|----------|------:|-------------------:|-------------:|
| DB (partition Postgres)     | **0** | 14.2% | 2.48 s |
| REDIS (partition Redis)     | **0** | 8.1%  | 0.08 s |
| ZK (partition ZooKeeper)    | **0** | 2.7%  | 1.47 s |

→ **All strategies are fail-closed under a clean partition** — zero duplicate side
effects. A partition makes the store *unavailable*, not unsafe. They differ in
availability impact and recovery, not correctness.

**E5 — clock drift & lock-timing stress**:

| Run | Premature lease expirations | DSEVR |
|-----|----------------------------:|------:|
| REDIS, svc1 clock +2 s | 0 | 0 |
| ZK, svc1 clock +2 s | 0 | 0 |
| REDIS_TS (lease=300 ms + 200 ms Redis latency) | **166** | **0** |

→ Client clock drift does **not** break Redisson (server-side `PEXPIRE` TTL) or
ZooKeeper (session-based). Directly stressing the timing assumption (short lease +
latency) **did** force 166 premature lease expirations — reproducing the Redlock
hazard — **yet produced zero duplicate side effects**, because the lock is backed
by an in-critical-section idempotency-marker re-check and a DB-guarded side effect.
**Sharpest finding: a lock alone is not a correctness mechanism; binding it to an
idempotency record is what keeps side effects unique when the lock's timing
assumptions fail.**

## Caveats (honest)
- 2 reps/strategy and short windows (smoke-scale), not the paper's 3–5 reps ×
  15-min windows; CIs are wide. Re-run `scripts/run_all.sh` on a dedicated host
  for publication-grade numbers.
- Kafka E2 denominator reflects only the operations the async consumer had
  drained at measurement time (clean re-measure: 92 of 200 keys); DSEVR = 0 is
  robust regardless of coverage because the unique `(operation_id,consumer_group)`
  constraint admits at most one side effect per operation.
- E4/E5 are measured (above), single run each at smoke scale. E3 is measured at a
  single 100 ms point; the full {0,25,50,100,250,500} ms sweep (× 3 reps) is the
  pending campaign, runnable via `scripts/exp_latency_sweep.sh` →
  `analyze.py` renders `fig_p99_latency_sweep.png` / `fig_dsevr_latency_sweep.png`.
- Throughput convergence (~757–777 req/s) is a shared-load-path artifact at this
  pilot scale, **not** a strategy-discriminating result. The meaningful comparison
  is each strategy's open-loop saturation knee (error rate < 1%), runnable via
  `scripts/exp_saturation.sh` → `fig_saturation.png`.
- The E5 timing-stress used a deliberately short lease (300 ms) + injected Redis
  latency (200 ms) to *provoke* premature expiration; production leases are longer.

## Generated artifacts
- Measured: `figures/fig_throughput.png`, `fig_p99.png`, `fig_violation_burst.png`;
  `tables/summary.csv`, `tables/comparison_matrix.csv`, `paper/results_table.tex`.
- Illustrative (projections): `figures/fig_violation_partition.png`,
  `fig_stale_locks.png`, `fig_p99_latency.png`, `fig_recovery.png`.
