# Related Work (working draft for §2)

## 2.1 Foundations of distributed coordination

Lamport's *Time, Clocks, and the Ordering of Events* [lamport1978clocks]
established that distributed processes share no global clock and that events are
only partially ordered. This result is the root cause of the timing hazards we
probe in the clock-drift experiment (E5): any locking scheme that infers
ownership from wall-clock time or a TTL is making an assumption that the network
and the operating system are free to violate.

Coordination kernels make safe agreement practical. Chubby [burrows2006chubby]
offers coarse-grained locks backed by Paxos and, critically, hands clients a
*sequencer* (a fencing token) so that a delayed lock-holder cannot corrupt state
after its lease has lapsed. ZooKeeper [hunt2010zookeeper] provides a wait-free
hierarchical namespace whose ephemeral, sequential znodes are the standard
substrate for distributed locks in the JVM ecosystem (via Apache Curator). etcd
builds equivalent guarantees on Raft [ongaro2014raft], whose explicit goal of
*understandability* has made it the coordination layer of cloud-native systems.
Spanner [corbett2012spanner] takes the opposite tack on time: rather than assume
clocks agree, TrueTime *bounds* their uncertainty and waits it out, achieving
external consistency. These systems define the correctness ceiling that
lightweight locks (Strategy B) are measured against.

## 2.2 Transactions, sagas, and the limits of strict consistency

Helland's *Life Beyond Distributed Transactions* [helland2007apostate] argues that
strict two-phase-commit transactions do not scale across entities, and that
scalable systems must instead decompose work into entities that exchange
*idempotent, at-least-once* messages — precisely the model this paper evaluates.
Sagas [garciamolina1987sagas] replace global atomicity with sequences of local
transactions plus compensations; the pattern has been refined for microservices
[mdpi2022saga, richardson_saga]. These approaches address *atomicity* across
services; they are complementary to, not substitutes for, the *duplicate
side-effect* problem, which persists within each local step.

## 2.3 Messaging semantics and event-driven idempotency

Kafka [kreps2011kafka] popularised the durable, log-structured broker; its
practical default is at-least-once delivery, so consumers must tolerate
redelivery. The transactional outbox pattern [richardson_outbox] closes the gap
between a database commit and an event publish by writing both in one local
transaction and relaying asynchronously — at the cost of possible duplicate
*publication*, which again pushes idempotency onto the consumer. Dynamo
[decandia2007dynamo] and the CAP theorem [gilbert2002cap] frame the unavoidable
trade-off: under partition a system chooses consistency or availability, and the
choice determines whether duplicate side effects become possible (our E4).

## 2.4 The Redlock debate

Whether a TTL-based Redis lock is safe for correctness is unsettled. Kleppmann
[kleppmann2016locking] shows that without a fencing token, a process paused by GC
or delayed by the network can act after its lease expires, and that Redlock's
safety leans on timing assumptions that clock drift can break. Sanfilippo
[sanfilippo2016redlock] replies that, under a stated failure model, Redlock holds.
We do not resolve the debate analytically; instead E3/E4/E5 measure where a Redis
lock actually begins to admit duplicate side effects.

## 2.5 Industrial idempotency practice

Stripe [stripe2017idempotency], Airbnb [airbnb2018doublepayments], and Brandur
[leels2017idempotencypostgres] document production idempotency: an
`Idempotency-Key` bound to a request fingerprint, an idempotency table guarded by
a unique constraint, and recovery points so retries resume safely. These inform
Strategy A and Strategy F (payload-hash binding). They are, however,
single-mechanism narratives without controlled comparison.

## 2.6 Gap and positioning

Recent academic and practitioner work treats these mechanisms in isolation or
qualitatively: the Uplatz survey [uplatz2025locking] compares Redis, ZooKeeper,
and consensus locking descriptively; the service-mesh idempotency study
[scitepress2025idempotency] targets fog resiliency; the DDD simulator
[ddd2026simulator] models business-logic-rich microservices but not idempotency
trade-offs. **No prior work offers a reproducible, fault-injected, quantitative
comparison of database-level idempotency, Redis locking, consensus coordination,
Kafka consumer idempotency, and transactional outbox under identical workloads,
evaluated with a domain-independent correctness metric.** This paper closes that
gap and contributes the *Duplicate Side-Effect Violation Rate* as that metric.
