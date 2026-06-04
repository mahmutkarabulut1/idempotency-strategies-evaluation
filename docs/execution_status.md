# Execution Status (against the 8-phase research plan)

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 1. Literature review | `docs/related_work.md`, `paper/references.bib`, `docs/research_questions.md`, `docs/literature_matrix.md` | **Done** |
| 2. Architecture design | `docker-compose.yml`, `db/schema.sql`, `toxiproxy-scenarios/`, `prometheus/`, `grafana/`, `docs/architecture.md`, `docs/fault_injection_plan.md` | **Done** |
| 3. Application | Spring Boot service, 6 strategies, metrics, Kafka consumer, outbox relay, unit tests | **Done — compiles, packages, tests pass** |
| 4. Workload + faults | `load-tests/k6/*`, `load-tests/datagen.py`, `scripts/faults.sh`, `clock_drift.sh`, `kafka_crash.sh`, `experiment_runner.sh` | **Done — bash syntax-checked** |
| 5. Measurement | `scripts/collect_metrics.sh`, `correctness_queries.sql`, `wait_healthy.sh`, `docs/environment_template.md` | **Done (tooling)** — *requires running the grid on real hardware* |
| 6. Analysis | `analysis/analyze.py`, `make_projections.py`; figures + tables generated | **Done — pipeline verified end-to-end** |
| 7. Paper | `paper/main.tex` (IEEEtran), `references.bib`, `Makefile` | **Done — needs LaTeX to render PDF; results figures currently ILLUSTRATIVE** |
| 8. Artifact finalization | `README.md`, `LICENSE`, `CITATION.cff`, `.gitignore`, `.dockerignore` | **Done** |

## What is verified in this environment
- `mvn package` (Java 21) succeeds; `PayloadHasherTest` 4/4 pass.
- **The grid was actually executed** on this host (Docker): strategies DB, REDIS,
  ZK, KAFKA each booted through the full stack (deps → Toxiproxy → 3 JVMs → nginx)
  and were measured for E1 + E2. See `results/aggregate.csv`, `results/run_all.log`.
- **Measured headline:** DSEVR = 0 for all four strategies under burst; warm-run
  p99 ordering Kafka 1.5 ms < DB 8 ms < Redis 23 ms < ZooKeeper 189 ms
  (`results/result_summary.md`, `paper/results_table.tex`).
- **Fault experiments measured** (`scripts/exp_partition.sh`, `exp_clockdrift.sh`):
  E4 partition — all strategies fail-closed (DSEVR 0; differ in error rate /
  recovery). E5 — client clock drift (+2 s, libfaketime) breaks neither Redisson
  (server-side TTL) nor ZooKeeper (session); a short-lease+latency timing stress
  forced **166 premature lease expirations with still-zero DSEVR**
  (`paper/fault_table.tex`). E3 has a single measured point (100 ms); the full
  {0,25,50,100,250,500} ms sweep is pending (`scripts/exp_latency_sweep.sh`).
- `analysis/analyze.py` emits MEASURED figures/tables for E1/E2/E3/E4/E5/E6/E7.
- All shell scripts pass `bash -n`.

## Data-adequacy targets (from peer review) and the campaigns that satisfy them

The current `results/aggregate.csv` is **pilot scale** (E1 n=2, E2–E7 n=1, E3 a
single 100 ms point). Turnkey campaigns are now provided to reach publication
scale; each requires a dedicated measurement host + time.

| Item (review) | Target | Driver |
|---------------|--------|--------|
| CW1 replication | E1/E2 ≥ 5 reps × 15-min; E4–E7 ≥ 3 reps | `experiment_runner.sh` with `REPS` |
| CW2 open-loop throughput | per-strategy saturation knee (1% error) | `scripts/exp_saturation.sh` → `results/saturation.csv` → `fig_saturation.png` |
| CW3 latency sweep | {0,25,50,100,250,500} ms × 3 reps | `scripts/exp_latency_sweep.sh` → `fig_p99_latency_sweep.png`, `fig_dsevr_latency_sweep.png` |
| SW1 resource util. | CPU/heap/pool/lag per strategy | `scripts/collect_metrics.sh` (queries added) |

## What remains (requires a measurement host + time)
1. Execute `scripts/experiment_runner.sh` across the strategy × scenario × rep grid
   with the review's replication counts (E1/E2 `REPS=5`, fault scenarios `REPS=3`),
   then `scripts/exp_saturation.sh` and `scripts/exp_latency_sweep.sh` for the
   open-loop and sweep campaigns.
2. Aggregate per-run outputs into `results/aggregate.csv` (one row per
   scenario,strategy,run,metric,value). The DB ground truth comes from
   `v_violation_rate`; performance from Prometheus exports. The saturation and
   sweep scripts append their rows automatically.
3. Re-run `analyze.py` → real figures replace the ILLUSTRATIVE ones (CI lower
   bounds are clamped at 0 and each bar is annotated with its rep count `n`);
   remove the red note and `[ILLUSTRATIVE]` tags in `paper/main.tex`.
4. Fill `docs/environment_template.md`, pin image digests.
5. `cd paper && make` to build the PDF; submit via IEEE ScholarOne with the
   artifact link + Zenodo DOI.

## Engineering issues found & fixed during live bring-up
These were caught by actually running the stack (not just compiling):
1. **Spring nested repositories ignored.** `Repositories.*` interfaces are nested;
   Spring Data skips nested repository interfaces unless
   `@EnableJpaRepositories(considerNestedRepositories = true)` — added in `JpaConfig`.
2. **Nested `@Entity` name not resolvable in JPQL.** `OutboxEvent` is a nested
   entity; its HQL name had to be pinned with `@Entity(name = "OutboxEvent")`.
3. **Redisson starter auto-connected to localhost:6379** at startup for every
   strategy, crashing DB-only runs. Switched `redisson-spring-boot-starter` →
   plain `redisson`; the client is now created only for the REDIS strategy in
   `CoordinationConfig`.
4. **ZooKeeper healthcheck** used the `ruok` 4lw word (not whitelisted by default);
   switched to `srvr` + `ZOOKEEPER_4LW_COMMANDS_WHITELIST`.
5. **Kafka single advertised listener** pointed at Toxiproxy, creating a
   broker-self-connection deadlock (Toxiproxy depends on Kafka health). Fixed with
   dual listeners: INTERNAL (direct) for broker traffic, EXTERNAL (via Toxiproxy)
   for clients.
6. **Kafka strategy minted a fresh operationId per request**, so same-key
   duplicates became distinct operations and the event-id dedup missed them
   (DSEVR would falsely read 0 while N side effects occurred). Fixed: operationId
   is now derived deterministically from the idempotency key, and the consumer
   dedups on `(operation_id, consumer_group)` via a unique constraint.

7. **Outbox `jsonb` insert failed silently at the API.** `outbox_events.payload`
   was `jsonb`, but the JDBC driver rejects a `varchar`-bound string with
   *"column is of type jsonb but expression is of type character varying"* — so
   every OUTBOX request returned HTTP 500 and no outbox row (hence no side effect)
   was ever written. The bug was invisible in throughput/latency (k6 counts 500s
   as completed requests) and only surfaced when the E2 side-effect count came
   back as 0. Fixed by storing the payload as `TEXT`. The OUTBOX numbers were then
   re-measured.
8. **E7 conflict accuracy was diluted by overload, not logic.** At 50 VUs the
   conflict test ran the testbed at ~75% request-failure; when the *first* request
   of a pair failed, the second was not a conflict. Conditioned on the first
   request committing, detection accuracy was exactly 1.0 (correct == first-applied).
   Re-run at 5 VUs it is 100%. (E2 burst denominators are likewise load/async-coverage
   dependent; the robust quantity is the violation count, which is 0 throughout.)

These are recorded because they are exactly the kind of correctness-vs-observability
pitfalls the paper argues practitioners must validate with a live, fault-injected
testbed rather than by code inspection alone. Notably, three of these bugs
(nested-repository, outbox jsonb, Kafka per-request id) were *silent* under
throughput/latency measurement and surfaced only through the correctness metric.

## Aggregation contract (results/aggregate.csv)
```
scenario,strategy,run,metric,value
E1,DB,run1,throughput,7723.4
E1,DB,run1,p99,93.2
E4,REDIS,run2,violation_rate,0.0039
...
```
`analyze.py` automatically prefers this file over the projections when present.
