#!/usr/bin/env python3
"""Synthetic workload generator for the idempotency study.

Produces a JSONL file of operation requests with controllable duplicate ratio and
burst structure. Uses Faker for realistic-but-synthetic values. NO real user,
payment, or personal data is produced.

Usage:
    python datagen.py --n 100000 --dup-ratio 0.10 --out workload.jsonl
"""
import argparse
import json
import random
import uuid

try:
    from faker import Faker
except ImportError:  # graceful fallback so the script runs without Faker installed
    Faker = None

OP_TYPES = ["PAYMENT", "ORDER_CREATION", "INVENTORY_RESERVATION", "WEBHOOK_DELIVERY",
            "NOTIFICATION_DISPATCH", "ACCOUNT_UPDATE", "BACKGROUND_JOB", "RESOURCE_BOOKING"]
REGIONS = ["us-east", "us-west", "eu-central", "ap-south", "sa-east"]


def build(n, dup_ratio, seed):
    random.seed(seed)
    fake = Faker() if Faker else None
    if fake:
        Faker.seed(seed)
    recent_keys = []
    rows = []
    for i in range(n):
        reuse = recent_keys and random.random() < dup_ratio
        if reuse:
            key = random.choice(recent_keys)
            retry = random.randint(1, 5)
        else:
            key = str(uuid.uuid4())
            recent_keys.append(key)
            if len(recent_keys) > 5000:
                recent_keys.pop(0)
            retry = 0
        rows.append({
            "idempotencyKey": key,
            "operationType": random.choice(OP_TYPES),
            "entityId": fake.uuid4() if fake else str(uuid.uuid4()),
            "userId": (fake.user_name() if fake else f"user-{random.randint(0, 9999)}"),
            "amount": round(random.uniform(1, 5000), 2),
            "quantity": random.randint(1, 10),
            "metadata": {"region": random.choice(REGIONS),
                         "client": (fake.bothify("cli-####") if fake else f"cli-{i % 1000}")},
            "retryAttempt": retry,
            "requestSource": f"gen-{seed}",
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100000)
    ap.add_argument("--dup-ratio", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="workload.jsonl")
    args = ap.parse_args()
    rows = build(args.n, args.dup_ratio, args.seed)
    with open(args.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    dup = sum(1 for r in rows if r["retryAttempt"] > 0)
    print(f"wrote {len(rows)} rows to {args.out} ({dup} duplicates, "
          f"{dup/len(rows):.1%}); Faker={'on' if Faker else 'off'}")


if __name__ == "__main__":
    main()
