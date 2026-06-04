# Literature Matrix

Maps each reference to the theme, the claim used, and where it is cited in the manuscript.

| # | Reference | Theme | Claim / contribution used | Cited in |
|---|-----------|-------|---------------------------|----------|
| 1 | Lamport 1978, *Time, Clocks, and Ordering* | Foundations | No global clock; events partially ordered → timing assumptions in TTL/lease locks are unsafe | Intro, H2/H5 motivation, Clock-drift experiment (E5) |
| 2 | Burrows 2006, *Chubby* | Coordination service | Lock service built on Paxos; coarse-grained locks + sequencers (fencing) for correctness | Related Work, Strategy C |
| 3 | Ongaro & Ousterhout 2014, *Raft* | Consensus | Understandable consensus underpinning etcd; leader election & log replication | Related Work, Strategy C (etcd) |
| 4 | Hunt et al. 2010, *ZooKeeper* | Coordination service | Wait-free coordination kernel, znodes, ephemeral nodes, watches → distributed locks | Related Work, Strategy C (ZooKeeper) |
| 5 | Corbett et al. 2012, *Spanner* | Time + transactions | TrueTime: bounded clock uncertainty enables external consistency | Discussion (clock drift, exactly-once) |
| 6 | Garcia-Molina & Salem 1987, *Sagas* | Long-lived transactions | Compensating transactions instead of global ACID | Related Work (alternatives), Discussion |
| 7 | Helland 2007, *Life Beyond Distributed Transactions* | Scalability | Strict distributed transactions don't scale → entity + activity (idempotent) messaging | Intro, System Model |
| 8 | Kreps et al. 2011, *Kafka* | Messaging | Log-structured broker; at-least-once delivery is the practical default | Strategy D/E, Background |
| 9 | DeCandia et al. 2007, *Dynamo* | High availability | AP trade-off, eventual consistency, app-level conflict resolution | Discussion (CAP trade-offs) |
| 10 | Gilbert & Lynch 2002, *CAP* | Theory | Cannot have C, A, P simultaneously under partition | Discussion (partition experiment E4) |
| 11 | Kleppmann 2016, *How to do distributed locking* | Redlock critique | Locks for correctness need fencing tokens; TTL locks unsafe under GC pause / clock skew | Strategy B, H2, E5 |
| 12 | Sanfilippo 2016, *Is Redlock safe?* | Redlock defense | Redlock counter-argument; assumptions and failure model | Strategy B, Threats to Validity |
| 13 | Stripe 2017, *Idempotency* | Industry | Idempotency-Key header, request fingerprint, recovery points | Strategy A/F, Design guidelines |
| 14 | Airbnb 2018, *Avoiding double payments* | Industry | Sponsor/accept tokens, idempotency in distributed payments | Intro motivation, Strategy A |
| 15 | Brandur 2017, *Idempotency keys in Postgres* | Industry | Atomic phases, idempotency table + unique constraint, recovery points | Strategy A implementation |
| 16 | Richardson, *Saga pattern* | Pattern catalog | Saga orchestration/choreography | Related Work |
| 17 | Richardson, *Transactional Outbox* | Pattern catalog | Outbox table written in same tx; relay publishes to broker | Strategy E |
| 18 | MDPI 2022, *Enhancing Saga* | Recent work | Saga improvements in microservices | Related Work |
| 19 | DDD Simulator 2026 (arXiv) | Recent work | Simulator for business-logic-rich microservices → testbed methodology | Related Work, Architecture |
| 20 | SciTePress 2025, *Idempotency in Service Mesh* | Recent work | Idempotency for fog-native resiliency | Related Work (gap: no comparative fault-injected eval) |
| 21 | Uplatz 2025, *Systematic Analysis of Distributed Locking* | Comparative survey | Qualitative Redis vs ZooKeeper vs consensus comparison | Related Work (gap: qualitative, not experimental) |
| 22 | Shopify, *Toxiproxy* | Tooling | Deterministic network fault injection | Methodology |

## Identified research gap

Existing work is either (a) **single-mechanism industry blogs** (Stripe, Airbnb,
Brandur), (b) **qualitative comparisons** (Uplatz), or (c) **foundational/theoretical**
(Lamport, CAP, Chubby, Raft). No prior work provides a **reproducible, fault-injected,
quantitative comparison** of database-level idempotency, Redis locking, consensus
coordination, Kafka consumer idempotency, and transactional outbox **under identical
workloads** with a **domain-independent correctness metric**. This study fills that gap.
