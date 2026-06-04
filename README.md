# Idempotency & Distributed Locking — Experimental Testbed

Reproducible, production-like, fault-injected testbed accompanying the IEEE Access
study *“A Comparative Experimental Evaluation of Idempotency and Distributed
Locking Strategies under High Concurrency and Fault Conditions.”*

It runs a single domain-independent **logical-operation service** (Java 21 /
Spring Boot 3) reconfigurable to one of six strategies, behind a load balancer and
a Toxiproxy fault layer, and measures both **performance** and a domain-independent
correctness metric — the **Duplicate Side-Effect Violation Rate (DSEVR)**.

> All workloads are **synthetic**; no real user, payment, or personal data is used.

## Strategies (`IDEM_STRATEGY`)

| Code | Strategy | Correctness primitive |
|------|----------|-----------------------|
| `DB` | PostgreSQL unique-constraint idempotency | unique key + one transaction |
| `REDIS` | Redis distributed lock (Redisson) | TTL lease + done-marker |
| `ZK` | ZooKeeper coordination (Curator) | session/quorum-bound znode |
| `KAFKA` | Kafka consumer idempotency | processed-message table |
| `OUTBOX` | Transactional outbox + idempotent consumer | outbox in same tx |
| `PAYLOAD_HASH` | Payload-hash-aware idempotency | key bound to payload hash |

## Repository layout

```
src/                Spring Boot service (6 strategies, metrics, Kafka, outbox)
db/schema.sql       Operation model + correctness views (v_violation_rate)
docker-compose.yml  Full testbed (3 svc instances, deps, Toxiproxy, Prom/Grafana)
toxiproxy-scenarios/ Proxy definitions
load-tests/         k6 scripts (baseline, duplicate-burst, conflict) + datagen.py
scripts/            faults.sh, clock_drift.sh, kafka_crash.sh, experiment_runner.sh
prometheus/ grafana/ Observability config + dashboard
analysis/           analyze.py, make_projections.py, requirements.txt
paper/              IEEE Access manuscript (main.tex, references.bib, Makefile)
results/            figures/, tables/, raw run outputs
docs/               research questions, related work, architecture, fault plan
```

## Quick start

```bash
# 1. Bring up the stack with a chosen strategy
IDEM_STRATEGY=DB EXPERIMENT_RUN=demo docker compose up -d --build
scripts/wait_healthy.sh
curl localhost:8080/operations/strategy        # -> DB

# 2. Send one operation (and a duplicate)
curl -s -XPOST localhost:8080/operations -H 'Content-Type: application/json' \
  -d '{"idempotencyKey":"k1","operationType":"PAYMENT","entityId":"e1","userId":"u1","amount":42.00,"quantity":1,"metadata":{},"retryAttempt":0,"requestSource":"manual"}'
# repeat the same call -> HTTP 200 DUPLICATE_REPLAYED, no second side effect

# 3. Run a load scenario
k6 run -e BASE=http://localhost:8080 -e BURST=100 -e OPS=500 -e RUN=demo \
  load-tests/k6/duplicate-burst.js

# 4. Check correctness ground truth
psql postgresql://idem:idem@localhost:5432/idemstudy -c \
  "SELECT * FROM v_violation_rate WHERE experiment_run='demo';"
```

## Inject faults

```bash
scripts/faults.sh latency redis 100 50     # E3: 100ms +-50ms latency on Redis
scripts/faults.sh partition redis 5        # E4: 5s partition
scripts/clock_drift.sh svc1 +0.5           # E5: 500ms clock drift on svc1
scripts/kafka_crash.sh svc2 before         # E6: consumer crash + redelivery
scripts/faults.sh clear redis              # remove toxics
```

## Run the full campaign (one command)

`scripts/run_campaign.sh` is the turnkey, right-sized measurement campaign. It
builds the images once, then runs every scenario in priority order — **E1**
(baseline + open-loop saturation sweep), **E2** (duplicate-burst DSEVR), **E3**
(latency sweep), then **E4–E7** (partition, clock drift, Kafka crash, conflict) —
with 60 s windows, 60 s warm-up, and 3 repetitions per cell. It writes
`results/aggregate.csv` + `results/saturation.csv`, checkpoints after each
strategy, logs to `results/campaign_run.log`, then regenerates all figures/tables
and (if a LaTeX toolchain is present) the PDF.

```bash
# foreground
bash scripts/run_campaign.sh

# or detached, so you can disconnect (recommended; ~4-6 h on a 20-core host)
tmux new-session -d -s campaign 'cd "$PWD" && bash scripts/run_campaign.sh'
tmux attach -t campaign                      # reattach
tail -f results/campaign_run.log             # or just follow the log
```

The rate grid is tuned per host (`SAT_RATES`); all parameters are overridable,
e.g. `REPS=5 WINDOW=900 bash scripts/run_campaign.sh` for publication scale. The
campaign is **serial by design** — concurrent load generators would contend for
CPU and corrupt the p99/throughput measurements.

## Full experiment grid + analysis (legacy / manual)

```bash
STRATEGIES="DB REDIS ZK KAFKA OUTBOX PAYLOAD_HASH" \
SCENARIOS="E1 E2 E3 E4 E5 E6 E7" REPS=3 scripts/experiment_runner.sh

cd analysis && pip install -r requirements.txt
python analyze.py        # reads results/aggregate.csv -> figures/ + tables/
```

If `results/aggregate.csv` is absent, `analyze.py` falls back to
`analysis/data/projections.csv` — **illustrative projections** generated by
`make_projections.py` (encoding hypotheses H1–H6, *not* measurements) so the
figure pipeline and manuscript placeholders render before the grid is executed.

## Requirements

Docker + Compose, Java 21 & Maven (for local builds), `k6`, `jq`, `psql`,
Python 3.10+. Component versions are pinned in `docs/architecture.md`.

## Reproducing the paper

```bash
cd paper && make            # builds main.pdf with IEEEtran (needs a LaTeX install)
```

## License

MIT — see `LICENSE`. Cite via `CITATION.cff`.
