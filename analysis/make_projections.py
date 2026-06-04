#!/usr/bin/env python3
"""Generate ILLUSTRATIVE projection data for the analysis pipeline.

These numbers are NOT measurements. They encode the directional predictions of
hypotheses H1-H6 (see docs/research_questions.md) with run-to-run noise, purely
so the figure/table tooling can be exercised and the manuscript can show
placeholder figures. Real runs overwrite results/aggregate.csv, after which
analyze.py ignores this file. Output: analysis/data/projections.csv
"""
import os
import numpy as np

OUT = os.path.join(os.path.dirname(__file__), "data", "projections.csv")
os.makedirs(os.path.dirname(OUT), exist_ok=True)
rng = np.random.default_rng(7)
REPS = 5

# (scenario, metric): {strategy: central_value}. Direction follows the hypotheses.
SPEC = {
    ("E1", "throughput"): {"DB": 7800, "REDIS": 11200, "ZK": 4300, "KAFKA": 12500, "OUTBOX": 6900, "PAYLOAD_HASH": 7600},
    ("E1", "p99"):        {"DB": 95,   "REDIS": 38,    "ZK": 180,  "KAFKA": 70,    "OUTBOX": 110,  "PAYLOAD_HASH": 98},
    ("E2", "violation_rate"): {"DB": 0.0, "REDIS": 0.0, "ZK": 0.0, "KAFKA": 0.0, "OUTBOX": 0.0, "PAYLOAD_HASH": 0.0},
    ("E2", "p99"):        {"DB": 240,  "REDIS": 65,    "ZK": 320,  "KAFKA": 90,    "OUTBOX": 180,  "PAYLOAD_HASH": 250},
    # Under partition (E4) the TTL Redis lock can admit duplicates; consensus/DB do not.
    ("E4", "violation_rate"): {"DB": 0.0, "REDIS": 0.0042, "ZK": 0.0, "KAFKA": 0.0, "OUTBOX": 0.0, "PAYLOAD_HASH": 0.0},
    ("E4", "recovery_s"): {"DB": 3.1, "REDIS": 6.8, "ZK": 9.5, "KAFKA": 12.0, "OUTBOX": 11.2, "PAYLOAD_HASH": 3.2},
    ("E3", "p99"):        {"DB": 130,  "REDIS": 260,   "ZK": 470,  "KAFKA": 150,   "OUTBOX": 190,  "PAYLOAD_HASH": 132},
    # Clock drift (E5): only TTL-lease (Redis) shows stale-lock acquisitions.
    ("E5", "stale_locks"): {"DB": 0, "REDIS": 37, "ZK": 0, "KAFKA": 0, "OUTBOX": 0, "PAYLOAD_HASH": 0},
}


def noisy(metric, val):
    if val == 0:
        return 0.0
    scale = 0.06 if metric in ("throughput", "p99") else 0.15
    return max(0.0, float(val * (1 + rng.normal(0, scale))))


def main():
    lines = ["scenario,strategy,run,metric,value"]
    for (scn, metric), per in SPEC.items():
        for strat, central in per.items():
            for r in range(1, REPS + 1):
                lines.append(f"{scn},{strat},run{r},{metric},{noisy(metric, central):.6f}")
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {len(lines)-1} ILLUSTRATIVE rows to {OUT}")
    print("NOTE: projections only — not measurements. See module docstring.")


if __name__ == "__main__":
    main()
