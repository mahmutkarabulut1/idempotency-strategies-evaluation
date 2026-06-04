// E2 — Duplicate burst. For each logical operation, fire N concurrent requests
// that all carry the SAME idempotency key, spread across VUs (and therefore
// across the three JVM instances via nginx). This is the contention / correctness
// stress test: at most one side effect must result per key.
//
//   k6 run -e BASE=http://localhost:8080 -e BURST=100 -e RUN=e2-redis-run1 duplicate-burst.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { scenario } from 'k6/execution';

const applied = new Counter('op_applied');
const duplicate = new Counter('op_duplicate');
const rejected = new Counter('op_rejected');

const BASE = __ENV.BASE || 'http://localhost:8080';
const BURST = parseInt(__ENV.BURST || '100');   // duplicates per logical op: 10/50/100/500
const RUN = __ENV.RUN || 'adhoc';
const OPS = parseInt(__ENV.OPS || '500');        // number of distinct logical operations

export const options = {
  scenarios: {
    burst: {
      executor: 'shared-iterations',
      vus: BURST,                 // BURST concurrent requests in flight
      iterations: OPS * BURST,    // each logical op gets BURST attempts
      maxDuration: '20m',
    },
  },
};

export default function () {
  // All BURST iterations of the same logical op share one key.
  const opIndex = Math.floor(scenario.iterationInTest / BURST);
  const key = `${RUN}-op-${opIndex}`;
  const body = JSON.stringify({
    idempotencyKey: key,
    operationType: 'PAYMENT',
    entityId: `ent-${opIndex}`,
    userId: `user-${opIndex % 1000}`,
    amount: '42.00',
    quantity: 1,
    metadata: {},
    retryAttempt: 0,
    requestSource: 'k6-burst',
  });
  const res = http.post(`${BASE}/operations`, body, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'no 5xx': (r) => r.status < 500 });
  if (res.status === 201) applied.add(1);
  else if (res.status === 200) duplicate.add(1);
  else if (res.status === 429) rejected.add(1);
}
