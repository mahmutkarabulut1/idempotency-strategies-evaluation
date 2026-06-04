// Sustained constant-rate load over a SMALL key space, so many requests race on
// the same idempotency key concurrently. Used by the E4 (partition) and E5
// (clock-drift / timing-stress) experiments: a fault injected mid-run lands while
// locks are contended. Fixed payload per key => duplicates are genuine retries
// (200), never spurious conflicts (409).
//   k6 run -e BASE=... -e RUN=p-redis -e RATE=300 -e DUR=50s -e NKEYS=50 fault_load.js
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const applied = new Counter('op_applied');
const duplicate = new Counter('op_duplicate');
const conflict = new Counter('op_conflict');
const rejected = new Counter('op_rejected');
const errors = new Counter('op_error');

const BASE = __ENV.BASE || 'http://nginx:8080';
const RUN = __ENV.RUN || 'flt';
const RATE = parseInt(__ENV.RATE || '300');
const DUR = __ENV.DUR || '50s';
const NKEYS = parseInt(__ENV.NKEYS || '50');

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
  scenarios: {
    fault: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DUR,
      preAllocatedVUs: Math.max(100, RATE), maxVUs: Math.max(400, RATE * 2),
    },
  },
};

// Deterministic payload per key (fixed amount) so reuse == genuine retry.
function bodyFor(idx) {
  return JSON.stringify({
    idempotencyKey: `flt-${RUN}-${idx}`,
    operationType: 'PAYMENT',
    entityId: `ent-${idx}`, userId: `user-${idx}`,
    amount: (100 + idx).toFixed(2), quantity: 1,
    metadata: {}, retryAttempt: 0, requestSource: 'k6-fault',
  });
}

export default function () {
  const idx = Math.floor(Math.random() * NKEYS);
  let res;
  try {
    res = http.post(`${BASE}/operations`, bodyFor(idx),
      { headers: { 'Content-Type': 'application/json' }, timeout: '10s' });
  } catch (e) {
    errors.add(1); return;
  }
  if (res.status === 201) applied.add(1);
  else if (res.status === 200) duplicate.add(1);
  else if (res.status === 409) conflict.add(1);
  else if (res.status === 429) rejected.add(1);
  else errors.add(1);     // 5xx / 0 (connection failures during partition)
}
