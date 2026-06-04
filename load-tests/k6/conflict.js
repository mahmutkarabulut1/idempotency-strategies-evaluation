// E7 — Conflicting payload with same idempotency key.
// For each key: request 1 establishes payload H1; request 2 reuses the key with a
// DIFFERENT payload (H2 != H1). The system must answer 409 CONFLICT to #2, not a
// 200 replay. Measures conflict-detection accuracy (run with IDEM_STRATEGY=PAYLOAD_HASH
// vs a key-only baseline to show the difference).
//
//   k6 run -e BASE=http://localhost:8080 -e RUN=e7-payloadhash conflict.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { scenario } from 'k6/execution';

const correctConflict = new Counter('correct_conflict');     // 409 on the conflicting 2nd req
const incorrectReplay = new Counter('incorrect_replay');     // 200/201 on conflicting 2nd req
const firstApplied = new Counter('first_applied');

const BASE = __ENV.BASE || 'http://localhost:8080';
const RUN = __ENV.RUN || 'adhoc';
// E7 measures conflict-detection CORRECTNESS, not throughput: run at low
// concurrency so the first request of each pair reliably commits before the
// second (conflicting) request is sent. High VUs only overload the testbed and
// dilute the metric with first-request failures.
const VUS = parseInt(__ENV.VUS || '5');
const ITER = parseInt(__ENV.ITER || '2000');

export const options = {
  scenarios: {
    pairs: { executor: 'shared-iterations', vus: VUS, iterations: ITER, maxDuration: '10m' },
  },
};

function post(key, amount) {
  return http.post(`${BASE}/operations`, JSON.stringify({
    idempotencyKey: key, operationType: 'PAYMENT', entityId: 'e', userId: 'u',
    amount: amount, quantity: 1, metadata: {}, retryAttempt: 0, requestSource: 'k6-conflict',
  }), { headers: { 'Content-Type': 'application/json' } });
}

export default function () {
  const key = `${RUN}-conf-${scenario.iterationInTest}`;
  const r1 = post(key, '100.00');            // payload H1
  if (r1.status === 201) firstApplied.add(1);
  const r2 = post(key, '999.99');            // payload H2 != H1 -> must be CONFLICT
  if (r2.status === 409) correctConflict.add(1);
  else incorrectReplay.add(1);
  check(r2, { 'conflict detected': (r) => r.status === 409 });
}
