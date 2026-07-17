// Transfer load test against the SDK outbound API (dfsp-20x:4001).
// One POST /transfers runs the full journey (party lookup -> quote -> transfer)
// synchronously, so http_req_duration is true client-side e2e latency.
//
// Scenarios (SCENARIO env var):
//   soak (default) - constant arrival rate at TPS for DURATION.
//                    p99 needs samples: at 1 TPS run >= 30m, at 10 TPS >= 10m.
//   ramp           - steps through RAMP_STEPS (default 1..15 TPS), holding each
//                    for STEP, to find where p99 crosses the SLO.
//
// See README.md for usage and the Prometheus remote-write output settings.

import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { DFSPS, N, outboundUrl, msisdn, uuid, pick } from './lib.js';

const TPS = Number(__ENV.TPS || 1);
const DURATION = __ENV.DURATION || '30m';
const STEP = __ENV.STEP || '2m';
const SCENARIO = __ENV.SCENARIO || 'soak';
const RAMP_STEPS = (__ENV.RAMP_STEPS || '1,2,4,6,8,10,12,15').split(',').map(Number);
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '5s';

// Ramp to each step's rate in 30s, then hold it for STEP.
const rampStages = RAMP_STEPS.flatMap((rate) => [
  { duration: '30s', target: rate },
  { duration: STEP, target: rate },
]);

const scenarios = {
  soak: {
    // 90s ramp-in before holding TPS: a cold jump to the target rate
    // queues transfers behind connection/cache warmup and the open model
    // never recovers (see soak-target-5tps in perf/RESULTS.md)
    executor: 'ramping-arrival-rate',
    startRate: 1,
    timeUnit: '1s',
    stages: [
      { duration: '90s', target: TPS },
      { duration: DURATION, target: TPS },
    ],
    preAllocatedVUs: Math.max(20, TPS * 10),
    maxVUs: Math.max(50, TPS * 20),
    exec: 'transfer',
  },
  ramp: {
    executor: 'ramping-arrival-rate',
    startRate: RAMP_STEPS[0],
    timeUnit: '1s',
    stages: rampStages,
    preAllocatedVUs: 150,
    maxVUs: 300,
    exec: 'transfer',
  },
};

export const options = {
  scenarios: { [SCENARIO]: scenarios[SCENARIO] },
  thresholds: {
    // Campaign SLO (revised 2026-07-02): p99 < 2s at 5 TPS on tps-1 hardware.
    // Stretch (next hardware): p99 < 1s — observed floor is ~715ms.
    http_req_duration: ['p(99)<2000'],
    http_req_failed: ['rate<0.01'],
    // Abort the run once sustained degradation sets in: past the breaking
    // point every request fails, which only poisons the system (backlogs,
    // stale-quote storms) without adding information.
    checks: [{ threshold: 'rate>0.95', abortOnFail: true, delayAbortEval: '2m' }],
    dropped_iterations: ['count<1'], // generator kept pace with the arrival rate
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

if (__ENV.TESTID) {
  options.tags = { testid: __ENV.TESTID };
}

// Terminal state of each transfer (COMPLETED / ERROR_OCCURRED / http_<code> / unparseable)
const transferState = new Counter('transfer_state');

export function transfer() {
  const sender = pick(DFSPS);
  const receiver = pick(DFSPS.filter((d) => d !== sender));

  const res = http.post(
    `${outboundUrl(sender)}/transfers`,
    JSON.stringify({
      homeTransactionId: uuid(),
      from: { idType: 'MSISDN', idValue: msisdn(sender, Math.floor(Math.random() * N) + 1) },
      to: { idType: 'MSISDN', idValue: msisdn(receiver, Math.floor(Math.random() * N) + 1) },
      amountType: 'SEND',
      currency: 'XXX',
      amount: String(Math.floor(Math.random() * 100) + 1),
      transactionType: 'TRANSFER',
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: REQUEST_TIMEOUT, // a hung transfer counts as a failure, not a stuck VU
      tags: { name: 'POST /transfers' },
    }
  );

  let state = `http_${res.status}`;
  if (res.status === 200) {
    try {
      state = res.json('currentState') || 'unknown';
    } catch (e) {
      state = 'unparseable';
    }
  }
  transferState.add(1, { state });

  check(res, { 'transfer COMPLETED': () => state === 'COMPLETED' });
}
