// Seed and verify test data for every participant in a topology.
//
// Two steps per participant:
//   1. register each MSISDN in that participant's own party repository
//      (one request each — there is no batch endpoint for this)
//   2. register the whole range in the scheme ALS (one batched request)
//
// Then verify. VERIFICATION IS THE POINT: this command owns the correctness
// of the test data, and a load run does not re-check it. Registering without
// confirming would leave the failure to surface later as discovery errors
// that look like a switch fault.
//
// Verification uses a single call per sample — GET {discovery}/MSISDN/<id> —
// because a 200 proves the whole chain at once: the ALS resolved the
// identifier AND the owning participant's repository answered for it. A
// separate repository check would be redundant.
//
// Samples rather than enumerates: first, last and a few in between. That
// distinguishes the failure modes that matter (nothing registered, registered
// to a smaller range, wrong range entirely) without a lookup per identifier.
//
// Idempotent. Re-registering an existing party is treated as success.

import http from 'k6/http';
import { Counter } from 'k6/metrics';

// Invoked through perf/bin/*.sh, which resolves the config first. Called
// directly without it, k6 would otherwise fail with an opaque Go stacktrace.
if (!__ENV.PERF_CONFIG) {
  throw new Error(
    'PERF_CONFIG is not set. Run this through `make perf-run` / `make perf-seed`, ' +
      'or set PERF_CONFIG to a resolved config JSON.'
  );
}
const CONFIG = JSON.parse(open(__ENV.PERF_CONFIG));
const VERIFY_SAMPLES = Number(__ENV.PERF_VERIFY_SAMPLES || 5);

const registered = new Counter('seed_registered');
const verified = new Counter('seed_verified');
const problems = new Counter('seed_problems');

const FIRST = ['Ada', 'Grace', 'Alan', 'Katherine', 'Amara', 'Kwame', 'Fatou', 'Rui'];
const LAST = ['Test', 'Kone', 'Diallo', 'Traore', 'Okafor', 'Santos', 'Nakamura', 'Haddad'];

// One VU per participant, so participants seed concurrently rather than one
// after another. Within a participant the requests are issued in a batch.
export const options = {
  scenarios: {
    seed: {
      executor: 'per-vu-iterations',
      vus: CONFIG.participants.length,
      iterations: 1,
      maxDuration: __ENV.PERF_SEED_MAX_DURATION || '60m',
    },
  },
  // Seeding writes; it must not be silently partial.
  thresholds: { seed_problems: ['count<1'] },
  discardResponseBodies: false,
};

const JSON_HEADERS = { 'Content-Type': 'application/json' };

function pick(a) {
  return a[Math.floor(Math.random() * a.length)];
}

// Chunked so a large range does not build one enormous request array.
function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

export default function () {
  const idx = (__VU - 1) % CONFIG.participants.length;
  const p = CONFIG.participants[idx];
  const { start, end } = p.msisdn;
  const total = end - start + 1;

  console.log(`[${p.id}] seeding ${total} identifiers (${start}..${end})`);

  // --- 1. party repository, one request per identifier -------------------
  let repoOk = 0;
  for (const group of chunk(range(start, end), 200)) {
    const requests = group.map((msisdn) => {
      const fn = pick(FIRST);
      const ln = pick(LAST);
      return {
        method: 'POST',
        url: p.urls.register_sim,
        body: JSON.stringify({
          displayName: `${fn} ${ln}`,
          firstName: fn,
          middleName: 'A',
          lastName: ln,
          dateOfBirth: '1990-01-01',
          idType: 'MSISDN',
          idValue: String(msisdn),
        }),
        params: { headers: JSON_HEADERS, tags: { step: 'register_sim', participant: p.id } },
      };
    });

    for (const res of http.batch(requests)) {
      // Repositories commonly reject a duplicate with a 4xx/5xx naming the
      // conflict. Re-seeding an existing party is a success, not an error.
      const dup = res.body && String(res.body).toLowerCase().includes('already registered');
      if ((res.status >= 200 && res.status < 300) || dup) {
        repoOk++;
      } else {
        problems.add(1, { participant: p.id, step: 'register_sim' });
        if (problems.name) console.error(`[${p.id}] repo ${res.status}: ${String(res.body).slice(0, 200)}`);
      }
    }
  }
  registered.add(repoOk, { participant: p.id, step: 'register_sim' });
  console.log(`[${p.id}] repository: ${repoOk}/${total}`);

  // --- 2. ALS, batched, check-before-write --------------------------------
  // IDEMPOTENCY IS NOT FREE HERE. Re-registering an identifier the ALS
  // already knows returns errorCode 3105 "Invalid signature" rather than a
  // duplicate error: the hub's rejection comes back as an error response
  // whose JWS the SDK cannot validate, and the signature failure masks the
  // real cause. So a duplicate is indistinguishable from a genuine signing
  // problem, and swallowing 3105 would hide a real fault.
  //
  // The way out is to not write what is already there. Probe first; register
  // only if the range is absent; and on a chunk failure, probe that chunk
  // before calling it a problem.
  const asker0 = CONFIG.participants.find((q) => q.id !== p.id) || p;
  const resolves = (msisdn) =>
    http.get(`${asker0.urls.discovery}/MSISDN/${msisdn}`, {
      timeout: '30s',
      tags: { step: 'als_probe', participant: p.id },
    }).status === 200;

  let alsOk = 0;
  const probe = sampleRange(start, end, Math.min(3, total));
  if (probe.every(resolves)) {
    alsOk = total;
    console.log(`[${p.id}] als: already registered (${probe.length} probes resolved) — skipped`);
  } else {
    for (const group of chunk(range(start, end), 1000)) {
      const body = group.map((m) => ({ idType: 'MSISDN', idValue: String(m) }));
      const res = http.post(p.urls.register_als, JSON.stringify(body), {
        headers: JSON_HEADERS,
        timeout: __ENV.PERF_SEED_ALS_TIMEOUT || '300s',
        tags: { step: 'register_als', participant: p.id },
      });
      if (res.status >= 200 && res.status < 300) {
        alsOk += group.length;
      } else if (sampleRange(group[0], group[group.length - 1], Math.min(3, group.length)).every(resolves)) {
        // Registration reported failure but the identifiers resolve, so this
        // chunk was already present. Idempotent, not broken.
        alsOk += group.length;
        console.log(`[${p.id}] als: chunk already present despite ${res.status} — treated as registered`);
      } else {
        problems.add(1, { participant: p.id, step: 'register_als' });
        console.error(`[${p.id}] als ${res.status}: ${String(res.body).slice(0, 300)}`);
      }
    }
    console.log(`[${p.id}] als: ${alsOk}/${total}`);
  }
  registered.add(alsOk, { participant: p.id, step: 'register_als' });

  // --- 3. verify ---------------------------------------------------------
  // Looked up from a DIFFERENT participant where possible: discovery is a
  // scheme-wide operation, and asking a peer is closer to what a real
  // transfer does than asking the owner about itself.
  const asker = CONFIG.participants.find((q) => q.id !== p.id) || p;
  // A range smaller than the sample count yields fewer distinct points, so
  // report against what was actually checked — "3/5" on a 3-identifier range
  // reads as two failures when nothing failed.
  const samples = sampleRange(start, end, VERIFY_SAMPLES);
  let ok = 0;
  for (const msisdn of samples) {
    const res = http.get(`${asker.urls.discovery}/MSISDN/${msisdn}`, {
      timeout: '30s',
      tags: { step: 'verify', participant: p.id },
    });
    if (res.status === 200) {
      ok++;
      verified.add(1, { participant: p.id });
    } else {
      problems.add(1, { participant: p.id, step: 'verify' });
      console.error(
        `[${p.id}] VERIFY FAILED for ${msisdn} via ${asker.id}: ${res.status} ${String(res.body).slice(0, 200)}`
      );
    }
  }
  console.log(`[${p.id}] verified ${ok}/${samples.length} sampled identifiers`);
}

function range(start, end) {
  const out = [];
  for (let i = start; i <= end; i++) out.push(i);
  return out;
}

// First, last, and evenly spaced points between — the shape that catches a
// range seeded to the wrong size.
function sampleRange(start, end, n) {
  if (end <= start || n <= 1) return [start];
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push(start + Math.round(((end - start) * i) / (n - 1)));
  }
  return [...new Set(out)];
}

export function handleSummary(data) {
  const count = (m) => (data.metrics[m] && data.metrics[m].values ? data.metrics[m].values.count : 0);
  const bad = count('seed_problems');
  const lines = [
    '',
    `registered   ${count('seed_registered')}`,
    `verified     ${count('seed_verified')} sampled lookups`,
    `problems     ${bad}`,
    '',
    bad === 0
      ? 'SEEDED — every sampled identifier resolves through the ALS.'
      : 'INCOMPLETE — see errors above. Do not treat load results from this\n             environment as valid until seeding reports clean.',
    '',
  ];
  return { stdout: lines.join('\n') };
}
