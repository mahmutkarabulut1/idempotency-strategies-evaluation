// E1 — Baseline high concurrency (no fault injection).
// Ramps TPS via stages; a configurable fraction of requests reuse a recent
// idempotency key (DUP_RATIO) to exercise the duplicate-suppression path.
//
//   k6 run -e BASE=http://localhost:8080 -e DUP_RATIO=0.05 -e RUN=e1-db-run1 baseline.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const applied = new Counter('op_applied');
const duplicate = new Counter('op_duplicate');
const conflict = new Counter('op_conflict');
const rejected = new Counter('op_rejected');

const BASE = __ENV.BASE || 'http://localhost:8080';
const DUP_RATIO = parseFloat(__ENV.DUP_RATIO || '0.05');
const RUN = __ENV.RUN || 'adhoc';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 500, timeUnit: '1s',
      preAllocatedVUs: 200, maxVUs: 2000,
      stages: [
        { target: 500,   duration: '5m' },   // warm-up
        { target: 1000,  duration: '3m' },
        { target: 2500,  duration: '3m' },
        { target: 5000,  duration: '3m' },
        { target: 10000, duration: '3m' },
        { target: 0,     duration: '2m' },   // cooldown
      ],
    },
  },
  thresholds: { http_req_duration: ['p(99)<2000'] },
};

const TYPES = ['PAYMENT','ORDER_CREATION','INVENTORY_RESERVATION','WEBHOOK_DELIVERY',
               'NOTIFICATION_DISPATCH','ACCOUNT_UPDATE','BACKGROUND_JOB','RESOURCE_BOOKING'];
const recentKeys = [];

function newKey() {
  const k = `${RUN}-${__VU}-${__ITER}-${Date.now()}`;
  if (recentKeys.length > 2000) recentKeys.shift();
  recentKeys.push(k);
  return k;
}
function pickKey() {
  if (Math.random() < DUP_RATIO && recentKeys.length > 0) {
    return recentKeys[Math.floor(Math.random() * recentKeys.length)];
  }
  return newKey();
}

export default function () {
  const key = pickKey();
  const body = JSON.stringify({
    idempotencyKey: key,
    operationType: TYPES[Math.floor(Math.random() * TYPES.length)],
    entityId: `ent-${__VU}`,
    userId: `user-${__VU % 1000}`,
    amount: (Math.random() * 1000).toFixed(2),
    quantity: 1,
    metadata: {},
    retryAttempt: 0,
    requestSource: `k6-vu-${__VU}`,
  });
  const res = http.post(`${BASE}/operations`, body, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status is 2xx/4xx': (r) => r.status > 0 });
  if (res.status === 201) applied.add(1);
  else if (res.status === 200) duplicate.add(1);
  else if (res.status === 409) conflict.add(1);
  else if (res.status === 429) rejected.add(1);
}
