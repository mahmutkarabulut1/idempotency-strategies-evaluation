// E1-S — Open-loop saturation probe (addresses review CW2). A single fixed
// offered rate via the constant-arrival-rate (open-loop) executor: k6 keeps
// dispatching RATE requests/s regardless of how fast the system replies, so a
// slow strategy backs up and its error rate rises instead of silently capping
// throughput at the load generator (the artifact that made all strategies look
// identical at ~776 req/s under a closed-loop ramp).
//
// scripts/exp_saturation.sh sweeps RATE across strategies and finds the knee
// where error rate first crosses 1% — the maximum sustainable throughput, which
// is the meaningful per-strategy throughput comparison.
//
//   k6 run -e BASE=http://localhost:8080 -e RATE=4000 -e DUR=120s -e RUN=sat-zk-4000 saturation.js
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const total = new Counter('op_total');
const errors = new Counter('op_error');   // status 0 (conn fail/timeout) or >=500

const BASE = __ENV.BASE || 'http://localhost:8080';
const RATE = parseInt(__ENV.RATE || '1000');
const DUR = __ENV.DUR || '120s';
const DUP_RATIO = parseFloat(__ENV.DUP_RATIO || '0.05');
const RUN = __ENV.RUN || 'sat';

export const options = {
  // p(99) must be requested explicitly or it is absent from --summary-export.
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
  scenarios: {
    sat: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DUR,
      preAllocatedVUs: Math.max(200, RATE),
      maxVUs: Math.max(1000, RATE * 4),   // headroom so VU starvation != saturation
    },
  },
};

const TYPES = ['PAYMENT','ORDER_CREATION','INVENTORY_RESERVATION','WEBHOOK_DELIVERY',
               'NOTIFICATION_DISPATCH','ACCOUNT_UPDATE','BACKGROUND_JOB','RESOURCE_BOOKING'];
const recentKeys = [];

function pickKey() {
  if (Math.random() < DUP_RATIO && recentKeys.length > 0) {
    return recentKeys[Math.floor(Math.random() * recentKeys.length)];
  }
  const k = `${RUN}-${__VU}-${__ITER}-${Date.now()}`;
  if (recentKeys.length > 2000) recentKeys.shift();
  recentKeys.push(k);
  return k;
}

export default function () {
  total.add(1);
  const body = JSON.stringify({
    idempotencyKey: pickKey(),
    operationType: TYPES[Math.floor(Math.random() * TYPES.length)],
    entityId: `ent-${__VU}`, userId: `user-${__VU % 1000}`,
    amount: (Math.random() * 1000).toFixed(2), quantity: 1,
    metadata: {}, retryAttempt: 0, requestSource: `k6-vu-${__VU}`,
  });
  let res;
  try {
    res = http.post(`${BASE}/operations`, body,
      { headers: { 'Content-Type': 'application/json' }, timeout: '10s' });
  } catch (e) {
    errors.add(1); return;
  }
  // 2xx applied/duplicate, 409 conflict and 429 rejected are valid responses;
  // only transport failures and 5xx count as saturation errors.
  if (res.status === 0 || res.status >= 500) errors.add(1);
}
