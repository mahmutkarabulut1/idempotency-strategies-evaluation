# Experiment Environment Capture

Fill this in for every measurement campaign so results are interpretable and
reproducible. Commit the completed copy alongside `results/`.

## Hardware
- CPU model / cores / threads:
- RAM:
- Storage (type, IOPS if known):
- Virtualization (bare metal / VM / cloud instance type):

## Software
- OS + kernel:
- Docker / Compose version:
- Java (Temurin) build:
- k6 version:
- Component image digests (pin, not just tags):
  - postgres:16 @ sha256:
  - redis:7 @ sha256:
  - cp-zookeeper:7.6.1 @ sha256:
  - cp-kafka:7.6.1 @ sha256:
  - toxiproxy:2.9.0 @ sha256:
  - prometheus:v2.54.1 @ sha256:
  - grafana:11.2.0 @ sha256:

## Run configuration
- IDEM_STRATEGY:
- Service instances: 3
- Hikari pool size:
- TPS levels / duplicate ratios used:
- Warm-up / measurement / cooldown: 5 / 15 / 2 min
- Repetitions:

## Notes / anomalies
-
