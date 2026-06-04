# Research Questions and Hypotheses

> Source positioning: A reproducible, production-like, fault-injected experimental
> evaluation of idempotency and distributed locking strategies in distributed
> microservice architectures. Target journal: **IEEE Access**.

## Core research problem

When the same logical operation reaches a distributed system multiple times
(retries, timeouts, concurrent requests, message redelivery, network partitions,
lock expiration, clock drift, consumer crashes), can the system guarantee that
**at most one successful side effect** is produced?

Central thesis:

> Distributed systems cannot always prevent duplicate *delivery*; therefore the
> primary engineering objective is to prevent duplicate *side effects* under
> realistic concurrency and failure conditions.

The three-level distinction that frames the paper:

| Level | Can it be prevented in general? |
|-------|---------------------------------|
| Duplicate delivery   | No (network/broker semantics)         |
| Duplicate processing | Often no                              |
| Duplicate side effect | **Yes — this is the design target**  |

## Research questions

- **RQ1 — Performance under high concurrency.** How do the strategies behave
  under high concurrency in throughput, latency (p50/p95/p99), and resource
  utilization, with no fault injection?
- **RQ2 — Correctness under fault conditions.** Which strategies produce
  duplicate side-effect violations under network partition, latency injection,
  clock drift, retry storms, and message redelivery?
- **RQ3 — Consistency vs performance trade-off.** What are the trade-offs across
  lock-free, lock-based, consensus-based, and event-driven strategies?
- **RQ4 — Failure boundary.** At what load level or fault severity does each
  strategy become impractical, unreliable, or inefficient? (Boundary-oriented,
  not winner-oriented.)
- **RQ5 — Reproducibility and observability.** How can these strategies be
  measured reproducibly in a production-like testbed?

## Hypotheses

- **H1 (DB-level idempotency).** PostgreSQL unique constraints give strong
  duplicate side-effect prevention but raise p99 under duplicate bursts due to
  unique-index contention and DB CPU saturation.
- **H2 (Redis lock).** Redis locks give low latency / high throughput normally,
  but correctness assumptions weaken under TTL/lease expiration, partition, and
  clock drift.
- **H3 (Consensus coordination).** ZooKeeper/etcd give stronger correctness under
  fault, but higher coordination latency, lower throughput, more ops complexity.
- **H4 (Kafka consumer idempotency).** Does not eliminate duplicate delivery, but
  with a processed-message store prevents duplicate side effects.
- **H5 (Outbox + idempotent consumer).** Improves end-to-end duplicate
  side-effect prevention, at the cost of storage overhead, complexity, and
  end-to-end latency.
- **H6 (Payload-hash validation).** Idempotency keys alone are insufficient for
  semantic correctness; binding keys to payload hashes improves conflict
  detection when the same key is reused with a different payload.

## Strategy ↔ RQ ↔ Experiment traceability

| Strategy | Primary RQ | Key experiments |
|----------|-----------|-----------------|
| A. PostgreSQL unique constraint | RQ1, RQ2, RQ4 | E1, E2, E4 |
| B. Redis distributed lock | RQ1, RQ2, RQ4 | E1, E2, E3, E4, E5 |
| C. ZooKeeper/etcd coordination | RQ2, RQ3, RQ4 | E1, E3, E4 |
| D. Kafka consumer idempotency | RQ2, RQ4 | E1, E6 |
| E. Transactional outbox + idempotent consumer | RQ2, RQ3 | E1, E6 |
| F. Payload-hash-aware idempotency | RQ2 | E7 |
