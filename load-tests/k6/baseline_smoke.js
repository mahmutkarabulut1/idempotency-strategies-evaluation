// Short baseline for live smoke runs (≈90s) — a time-bounded version of
// baseline.js for environments where the full 19-min ramp is impractical.
//   k6 run -e BASE=http://nginx:8080 -e DUP_RATIO=0.10 -e RUN=e1-db baseline_smoke.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const applied = new Counter('op_applied');
const duplicate = new Counter('op_duplicate');
const conflict = new Counter('op_conflict');
const rejected = new Counter('op_rejected');

const BASE = __ENV.BASE || 'http://nginx:8080';
const DUP_RATIO = parseFloat(__ENV.DUP_RATIO || '0.10');
const RUN = __ENV.RUN || 'adhoc';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 200, timeUnit: '1s',
      preAllocatedVUs: 100, maxVUs: 800,
      stages: [
        { target: 500,  duration: '20s' },  // warm-up
        { target: 1500, duration: '40s' },  // measurement
        { target: 0,    duration: '15s' },  // cooldown
      ],
    },
  },
};

const TYPES = ['PAYMENT','ORDER_CREATION','INVENTORY_RESERVATION','WEBHOOK_DELIVERY',
               'NOTIFICATION_DISPATCH','ACCOUNT_UPDATE','BACKGROUND_JOB','RESOURCE_BOOKING'];
// Keep the full payload per key so a reused key resends an IDENTICAL payload
// (a genuine retry -> 200 DUPLICATE_REPLAYED), not a different one (-> 409).
const recent = [];
function newReq() {
  const r = {
    idempotencyKey: `${RUN}-${__VU}-${__ITER}-${Date.now()}`,
    operationType: TYPES[Math.floor(Math.random() * TYPES.length)],
    entityId: `ent-${__VU}`, userId: `user-${__VU % 1000}`,
    amount: (Math.random() * 1000).toFixed(2), quantity: 1,
    metadata: {}, retryAttempt: 0, requestSource: `k6-vu-${__VU}`,
  };
  if (recent.length > 2000) recent.shift();
  recent.push(r);
  return r;
}
function pickReq() {
  if (Math.random() < DUP_RATIO && recent.length > 0)
    return recent[Math.floor(Math.random() * recent.length)];
  return newReq();
}

export default function () {
  const body = JSON.stringify(pickReq());
  const res = http.post(`${BASE}/operations`, body, { headers: { 'Content-Type': 'application/json' } });
  check(res, { 'ok': (r) => r.status > 0 && r.status < 500 });
  if (res.status === 201) applied.add(1);
  else if (res.status === 200) duplicate.add(1);
  else if (res.status === 409) conflict.add(1);
  else if (res.status === 429) rejected.add(1);
}
