// Seed test data: N parties per DFSP in the SDK test API repository,
// then batch-register the same MSISDNs in the ALS via the outbound API.
// Idempotent: re-registering an existing party/account is accepted.
//
//   k6 run seed.js            # 100 parties per DFSP (default)
//   N=1000 k6 run seed.js
//
// Must run (once per environment) before transfers.js, with the same N.

import http from 'k6/http';
import { check } from 'k6';
import { DFSPS, N, testApiUrl, outboundUrl, msisdn, pick } from './lib.js';

const FIRST = ['Paul', 'Alice', 'John', 'Maria', 'Ahmed', 'Fatou', 'Omar', 'Awa', 'Ibrahim', 'Salif'];
const LAST = ['Test', 'Kone', 'Diallo', 'Traore', 'Ouedraogo', 'Sawadogo', 'Zongo', 'Kabore', 'Sanou', 'Ilboudo'];

export const options = {
  scenarios: {
    seed: { executor: 'shared-iterations', vus: 1, iterations: 1, maxDuration: '30m' },
  },
  thresholds: {
    checks: ['rate>0.99'],
  },
};

const headers = { 'Content-Type': 'application/json' };

export default function () {
  for (const dfsp of DFSPS) {
    for (let i = 1; i <= N; i++) {
      const fn = pick(FIRST);
      const ln = pick(LAST);
      const res = http.post(
        `${testApiUrl(dfsp)}/repository/parties`,
        JSON.stringify({
          displayName: `${fn} ${ln}`,
          firstName: fn,
          middleName: 'A',
          lastName: ln,
          dateOfBirth: '1990-01-01',
          idType: 'MSISDN',
          idValue: msisdn(dfsp, i),
        }),
        { headers, tags: { name: 'POST /repository/parties' } }
      );
      check(res, {
        // sim-backend returns 500 "ID is already registered" on duplicates —
        // count re-seeding an existing party as success
        'party registered': (r) =>
          (r.status >= 200 && r.status < 300) || (r.body && r.body.includes('already registered')),
      });
    }

    const accounts = [];
    for (let i = 1; i <= N; i++) {
      accounts.push({ idType: 'MSISDN', idValue: msisdn(dfsp, i) });
    }
    const res = http.post(`${outboundUrl(dfsp)}/accounts`, JSON.stringify(accounts), {
      headers,
      timeout: '120s',
      tags: { name: 'POST /accounts' },
    });
    check(res, { 'accounts registered in ALS': (r) => r.status >= 200 && r.status < 300 });

    console.log(`[${dfsp}] seeded ${N} parties + ALS registrations`);
  }
}
