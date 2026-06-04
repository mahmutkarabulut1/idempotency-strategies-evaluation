# Experimental Architecture

```
                      ┌──────────────────────────┐
                      │   Load Generator (k6 /    │
                      │   Gatling): TPS levels,   │
                      │   duplicate ratios, bursts│
                      └─────────────┬─────────────┘
                                    │ HTTP
                      ┌─────────────▼─────────────┐
                      │   nginx load balancer      │  same idem-key can hit any JVM
                      └───┬───────────┬───────────┬┘
                          │           │           │
                 ┌────────▼──┐ ┌──────▼────┐ ┌────▼──────┐
                 │  svc1     │ │  svc2     │ │  svc3     │  Spring Boot 3.x / Java 21
                 │ (JVM)     │ │ (JVM)     │ │ (JVM)     │  strategy = ${IDEM_STRATEGY}
                 └────┬──────┘ └────┬──────┘ └────┬──────┘
                      └──────┬──────┴──────┬──────┘
                             │             │ /actuator/prometheus
                  ┌──────────▼─────────┐   │
                  │     Toxiproxy      │   │  latency / partition / reset
                  │  fault injection   │   │
                  └──┬────┬─────┬───┬──┘   │
                     │    │     │   │       │
              ┌──────▼┐ ┌─▼──┐ ┌▼──┐ ┌▼────┐│
              │Postgre│ │Redis│ │ZK │ │Kafka││
              │  SQL  │ │     │ │   │ │     ││
              └───────┘ └─────┘ └───┘ └─────┘│
                                             │
                  ┌──────────────────────────▼─┐
                  │ Prometheus ─► Grafana       │
                  │ + CSV/JSON export ─► Python  │
                  └─────────────────────────────┘
```

## Deployment topology

- **3 application instances** behind nginx → cross-process races on the same key.
- **Single instance** of each stateful dependency for scope control; Redlock-style
  multi-node Redis is an *optional extended* experiment.
- **Toxiproxy** sits on every dependency edge; nothing talks to a dependency
  directly. This is what makes faults deterministic and repeatable.
- **Consensus layer choice: ZooKeeper** (via Apache Curator) for the first version,
  for native JVM integration. etcd is documented as an alternative.

## Component versions (pinned for reproducibility)

| Component | Version |
|-----------|---------|
| Java | 21 (Temurin) |
| Spring Boot | 3.3.x |
| PostgreSQL | 16 |
| Redis | 7 (Redisson client) |
| ZooKeeper | 3.9 (cp-zookeeper 7.6.1) |
| Kafka | 3.7 (cp-kafka 7.6.1) |
| Toxiproxy | 2.9.0 |
| Prometheus | 2.54.1 |
| Grafana | 11.2.0 |
| Load generator | k6 0.52 (Gatling alternative documented) |

See `docs/environment_template.md` for the host hardware/software capture form.
