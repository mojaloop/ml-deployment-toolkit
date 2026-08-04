// Three-phase Mojaloop transfer load test.
//
// Each iteration runs discovery -> quote -> transfer as three separate calls
// against a participant's SDK scheme-adapter outbound API, timing each one.
// A single combined call would give one aggregate number and no attribution,
// which cannot answer "which phase got slower".
//
// CONFIG COMES FROM ONE RESOLVED FILE. perf/bin/lib.sh merges topology,
// scenario and CLI overrides into a single JSON and passes its path in
// PERF_CONFIG. This script parses no YAML, knows no defaults, and constructs
// no URLs: every endpoint arrives fully formed from the topology. The only
// thing appended anywhere is the identifier on discovery, which is data.
//
// COMPLIANCE IS COUNTED, NOT DERIVED. k6 exports percentiles it computed
// internally; you cannot recover "share under 1s" from a p95. So every
// iteration votes against each configured threshold via a tagged Rate, which
// remote-writes as k6_within_slo_rate{threshold="1"}. That is exact, and it
// matches the bucket boundaries the hub histograms use, so client-side and
// hub-side compliance are directly comparable.
//
// TRACESTATE IS DELIBERATELY NOT SET. Injecting one risks displacing the
// Mojaloop Event SDK's own vendor entry, which carries the timestamps hub
// metrics are derived from. traceparent alone is enough to correlate.

import http from 'k6/http';
import crypto from 'k6/crypto';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';

// Invoked through perf/bin/*.sh, which resolves the config first. Called
// directly without it, k6 would otherwise fail with an opaque Go stacktrace.
if (!__ENV.PERF_CONFIG) {
  throw new Error(
    'PERF_CONFIG is not set. Run this through `make perf-run` / `make perf-seed`, ' +
      'or set PERF_CONFIG to a resolved config JSON.'
  );
}
const CONFIG = JSON.parse(open(__ENV.PERF_CONFIG));

const PARTICIPANTS = {};
for (const p of CONFIG.participants) PARTICIPANTS[p.id] = p;

const PAIRS = CONFIG.pairs;
const SLO = CONFIG.slo;
const WORKLOAD = CONFIG.workload;
const TRACE_SAMPLE_EVERY_MS = Number(CONFIG.trace_sample_every_ms || 0);

// --- metrics ---------------------------------------------------------------
// isTime=true so k6 renders these as durations rather than bare numbers.
const e2eTime = new Trend('e2e_time', true);
const discoveryTime = new Trend('discovery_time', true);
const quoteTime = new Trend('quote_time', true);
const transferTime = new Trend('transfer_time', true);

const successRate = new Rate('success_rate');
const withinSlo = new Rate('within_slo');
const completed = new Counter('completed_transactions');
const failed = new Counter('failed_transactions');
// Terminal outcome per attempt, tagged by phase and reason, so a failure is
// attributable without reading logs.
const outcome = new Counter('transaction_outcome');

// --- scenario --------------------------------------------------------------
// VU allocation is derived from the target rate and an assumed worst-case
// iteration duration, never a fixed constant: too few and k6 throttles itself
// (reported as dropped iterations), too many wastes memory.
function vuBudget(peakTps) {
  const worstCaseSeconds = Math.max(2, secondsOf(CONFIG.request_timeout));
  const needed = Math.ceil(peakTps * worstCaseSeconds);
  return { pre: Math.max(20, needed), max: Math.max(50, needed * 3) };
}

function secondsOf(duration) {
  const m = String(duration).match(/^(\d+(?:\.\d+)?)(ms|s|m|h)$/);
  if (!m) return Number(duration) || 0;
  const n = Number(m[1]);
  return { ms: n / 1000, s: n, m: n * 60, h: n * 3600 }[m[2]];
}

function buildScenario() {
  const load = CONFIG.load;

  if (load.shape === 'ramp') {
    const peak = Math.max(...load.steps);
    const budget = vuBudget(peak);
    const stages = [];
    for (const rate of load.steps) {
      stages.push({ duration: load.step_ramp || '30s', target: rate });
      stages.push({ duration: load.step_duration, target: rate });
    }
    return {
      executor: 'ramping-arrival-rate',
      startRate: load.steps[0],
      timeUnit: '1s',
      stages,
      preAllocatedVUs: budget.pre,
      maxVUs: budget.max,
    };
  }

  // soak and smoke share the same executor; smoke is just short and warmup-free.
  const budget = vuBudget(load.tps);
  const stages = [];
  if (secondsOf(load.warmup) > 0) stages.push({ duration: load.warmup, target: load.tps });
  stages.push({ duration: load.duration, target: load.tps });
  return {
    executor: 'ramping-arrival-rate',
    startRate: secondsOf(load.warmup) > 0 ? 1 : load.tps,
    timeUnit: '1s',
    stages,
    preAllocatedVUs: budget.pre,
    maxVUs: budget.max,
  };
}

// k6 only materialises a tagged sub-metric if a threshold names it, and
// handleSummary can only read what was materialised. So EVERY threshold gets
// an entry — but only the target one actually gates. The rest use a condition
// that cannot fail; they exist purely so their compliance ratio reaches the
// report and the dashboards.
function buildThresholds() {
  const t = {
    success_rate: [`rate>=${SLO.success_rate}`],
    // If this fires the generator could not offer the load it claimed, and
    // the run's latency figures are not comparable to one that could.
    dropped_iterations: ['count<1'],
  };
  for (const v of SLO.thresholds) {
    t[`within_slo{threshold:${v}}`] =
      String(v) === String(SLO.target)
        ? // The gate is the compliance ratio at the target, not a percentile:
          // a percentile near a bucket boundary is interpolated, not measured.
          [`rate>=${SLO.success_rate}`]
        : ['rate>=0'];
  }
  return t;
}

export const options = {
  scenarios: { [CONFIG.load.shape]: buildScenario() },
  thresholds: buildThresholds(),
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  tags: { testid: __ENV.PERF_RUN_ID },
  noConnectionReuse: false,
  discardResponseBodies: false,
};

// --- helpers ---------------------------------------------------------------
function pickPair() {
  const total = PAIRS.reduce((s, p) => s + p.weight, 0);
  let r = Math.random() * total;
  for (const p of PAIRS) {
    r -= p.weight;
    if (r <= 0) return p;
  }
  return PAIRS[PAIRS.length - 1];
}

function randomMsisdn(participant) {
  const { start, end } = participant.msisdn;
  return String(Math.floor(Math.random() * (end - start + 1)) + start);
}

function hex(bytes) {
  const b = new Uint8Array(bytes);
  let s = '';
  for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
  return s;
}

// Head sampling: mark a trace as sampled at most once per interval, per VU 1.
// Module scope, not function scope — a counter reset on every call would
// sample everything and defeat the throttle.
let lastSampledAt = 0;
function traceparent() {
  let flags = '00';
  if (TRACE_SAMPLE_EVERY_MS > 0 && exec.vu.idInTest === 1) {
    const now = Date.now();
    if (now - lastSampledAt >= TRACE_SAMPLE_EVERY_MS) {
      flags = '01';
      lastSampledAt = now;
    }
  }
  return `00-${hex(crypto.randomBytes(16))}-${hex(crypto.randomBytes(8))}-${flags}`;
}

function ulid() {
  return (Date.now().toString(16).padStart(12, '0') + hex(crypto.randomBytes(7)))
    .toUpperCase()
    .slice(0, 26);
}

function headers(source, dest, tp) {
  const h = {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'FSPIOP-Source': source.id,
    Date: new Date().toUTCString(),
    traceparent: tp,
  };
  if (dest) h['FSPIOP-Destination'] = dest.id;
  return h;
}

function fail(phase, reason, source, dest) {
  outcome.add(1, { phase, reason, source: source.id, dest: dest.id });
  failed.add(1);
  successRate.add(0);
  for (const t of SLO.thresholds) withinSlo.add(false, { threshold: String(t) });
}

// --- iteration -------------------------------------------------------------
export default function () {
  const pair = pickPair();
  const source = PARTICIPANTS[pair.source];
  const dest = PARTICIPANTS[pair.dest];
  const tp = traceparent();
  const tagBase = { source: source.id, dest: dest.id };
  const payeeMsisdn = randomMsisdn(dest);
  const payerMsisdn = randomMsisdn(source);
  const transactionId = ulid();
  const quoteId = ulid();

  const started = Date.now();

  // Phase 1 — discovery. The identifier is data appended to the endpoint.
  const t0 = Date.now();
  const partyRes = http.get(`${source.urls.discovery}/MSISDN/${payeeMsisdn}`, {
    headers: headers(source, null, tp),
    timeout: CONFIG.request_timeout,
    tags: Object.assign({ phase: 'discovery' }, tagBase),
  });
  if (partyRes.status !== 200) {
    // A 404 here almost always means the identifier is not registered, i.e.
    // the environment is not seeded for this range — not a switch fault.
    fail('discovery', `http_${partyRes.status}`, source, dest);
    return;
  }
  discoveryTime.add(Date.now() - t0, tagBase);

  // Phase 2 — quote.
  const t1 = Date.now();
  const quoteRes = http.post(
    source.urls.quotes,
    JSON.stringify({
      fspId: dest.id,
      quotesPostRequest: {
        quoteId,
        transactionId,
        payer: {
          partyIdInfo: { partyIdType: 'MSISDN', partyIdentifier: payerMsisdn, fspId: source.id },
        },
        payee: {
          partyIdInfo: { partyIdType: 'MSISDN', partyIdentifier: payeeMsisdn, fspId: dest.id },
        },
        amountType: 'SEND',
        amount: { amount: WORKLOAD.amount, currency: WORKLOAD.currency },
        transactionType: { scenario: 'TRANSFER', initiator: 'PAYER', initiatorType: 'CONSUMER' },
      },
    }),
    {
      headers: headers(source, dest, tp),
      timeout: CONFIG.request_timeout,
      tags: Object.assign({ phase: 'quotes' }, tagBase),
    }
  );
  if (quoteRes.status !== 200) {
    fail('quotes', `http_${quoteRes.status}`, source, dest);
    return;
  }

  let quote;
  try {
    quote = quoteRes.json();
  } catch (e) {
    fail('quotes', 'unparseable', source, dest);
    return;
  }
  const ilpPacket = quote && quote.quotes && quote.quotes.body && quote.quotes.body.ilpPacket;
  const condition = quote && quote.quotes && quote.quotes.body && quote.quotes.body.condition;
  if (!ilpPacket || !condition) {
    fail('quotes', 'no_ilp', source, dest);
    return;
  }
  quoteTime.add(Date.now() - t1, tagBase);

  // Phase 3 — transfer, carrying the quote's ILP packet and condition.
  const t2 = Date.now();
  const transferRes = http.post(
    source.urls.transfers,
    JSON.stringify({
      fspId: dest.id,
      transfersPostRequest: {
        transferId: transactionId,
        payerFsp: source.id,
        payeeFsp: dest.id,
        amount: { amount: WORKLOAD.amount, currency: WORKLOAD.currency },
        ilpPacket,
        condition,
        expiration: new Date(Date.now() + 60000).toISOString(),
      },
    }),
    {
      headers: headers(source, dest, tp),
      timeout: CONFIG.request_timeout,
      tags: Object.assign({ phase: 'transfers' }, tagBase),
    }
  );
  if (transferRes.status !== 200) {
    fail('transfers', `http_${transferRes.status}`, source, dest);
    return;
  }
  transferTime.add(Date.now() - t2, tagBase);

  const elapsedMs = Date.now() - started;
  e2eTime.add(elapsedMs, tagBase);
  successRate.add(1);
  completed.add(1, tagBase);
  outcome.add(1, Object.assign({ phase: 'complete', reason: 'ok' }, tagBase));

  // One vote per threshold. Seconds, matching the hub histogram boundaries.
  const elapsedSeconds = elapsedMs / 1000;
  for (const t of SLO.thresholds) {
    withinSlo.add(elapsedSeconds <= t, { threshold: String(t) });
  }
}

// --- report ----------------------------------------------------------------
export function handleSummary(data) {
  const val = (name, key) => {
    const m = data.metrics[name];
    return m && m.values && m.values[key] !== undefined ? m.values[key] : null;
  };

  const compliance = {};
  for (const t of SLO.thresholds) {
    const sub = data.metrics[`within_slo{threshold:${t}}`];
    compliance[String(t)] = sub && sub.values ? sub.values.rate : null;
  }

  const targetCompliance = compliance[String(SLO.target)];
  const successValue = val('success_rate', 'rate');
  const dropped = val('dropped_iterations', 'count') || 0;

  const summary = {
    run_id: __ENV.PERF_RUN_ID,
    scenario: __ENV.PERF_SCENARIO,
    topology: __ENV.PERF_TOPOLOGY,
    generator: {
      host: __ENV.PERF_GENERATOR_HOST || 'unknown',
      note: 'network path from generator to participants is inside every latency figure',
    },
    // Whether this run's telemetry was shipped — NOT where to. Results are
    // committed, and endpoint URLs belong to the environment's config, not to
    // a result. Look them up in environments/<env>/perf-topology.yaml.
    telemetry: {
      metrics_pushed: Boolean((CONFIG.observability || {}).metrics_url),
      logs_pushed: __ENV.PERF_LOGS_SHIPPED === '1',
      // k6 emits no spans. Any traces for this run were produced by the hub
      // and DFSP services from the injected traceparent.
      traces_expected: Boolean((CONFIG.observability || {}).traces_url),
    },
    load: CONFIG.load,
    slo: SLO,
    results: {
      completed: val('completed_transactions', 'count') || 0,
      failed: val('failed_transactions', 'count') || 0,
      success_rate: successValue,
      dropped_iterations: dropped,
      // Bucket-exact: counted per iteration, not interpolated.
      compliance_by_threshold: compliance,
      compliance_at_target: targetCompliance,
      phases: {
        discovery: data.metrics.discovery_time ? data.metrics.discovery_time.values : null,
        quotes: data.metrics.quote_time ? data.metrics.quote_time.values : null,
        transfers: data.metrics.transfer_time ? data.metrics.transfer_time.values : null,
        e2e: data.metrics.e2e_time ? data.metrics.e2e_time.values : null,
      },
    },
    verdict: {
      // Explicitly separate: a run can be invalid without the system failing.
      generator_kept_pace: dropped < 1,
      slo_met:
        targetCompliance !== null &&
        targetCompliance >= SLO.success_rate &&
        successValue !== null &&
        successValue >= SLO.success_rate,
    },
  };

  const out = {};
  out[`${__ENV.PERF_OUT_DIR}/summary.json`] = JSON.stringify(summary, null, 2);
  out.stdout = renderText(summary);
  return out;
}

function renderText(s) {
  const pct = (v) => (v === null || v === undefined ? '   n/a' : (v * 100).toFixed(3) + '%');
  const ms = (v) => (v === null || v === undefined ? 'n/a' : Math.round(v) + 'ms');
  const p = s.results.phases;
  const lines = [
    '',
    `run           ${s.run_id}`,
    `scenario      ${s.scenario} on ${s.topology}`,
    `completed     ${s.results.completed}   failed ${s.results.failed}   dropped ${s.results.dropped_iterations}`,
    `success rate  ${pct(s.results.success_rate)}`,
    '',
    'phase latency          p50        p95        p99',
    `  discovery       ${ms(p.discovery && p.discovery.med)}   ${ms(p.discovery && p.discovery['p(95)'])}   ${ms(p.discovery && p.discovery['p(99)'])}`,
    `  quotes          ${ms(p.quotes && p.quotes.med)}   ${ms(p.quotes && p.quotes['p(95)'])}   ${ms(p.quotes && p.quotes['p(99)'])}`,
    `  transfers       ${ms(p.transfers && p.transfers.med)}   ${ms(p.transfers && p.transfers['p(95)'])}   ${ms(p.transfers && p.transfers['p(99)'])}`,
    `  e2e             ${ms(p.e2e && p.e2e.med)}   ${ms(p.e2e && p.e2e['p(95)'])}   ${ms(p.e2e && p.e2e['p(99)'])}`,
    '',
    'compliance (counted exactly, not interpolated)',
  ];
  for (const t of s.slo.thresholds) {
    const mark = String(t) === String(s.slo.target) ? '  <- gate' : '';
    lines.push(`  within ${String(t).padStart(5)}s      ${pct(s.results.compliance_by_threshold[String(t)])}${mark}`);
  }
  lines.push('');
  if (!s.verdict.generator_kept_pace) {
    lines.push('INVALID: the generator dropped iterations — it did not apply the load');
    lines.push('         this scenario asked for. These figures are not comparable.');
  }
  lines.push(`verdict       ${s.verdict.slo_met ? 'SLO MET' : 'SLO NOT MET'}`);
  lines.push('');
  return lines.join('\n');
}
