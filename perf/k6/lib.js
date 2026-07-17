// Shared configuration for the perf scripts.
//
// The MSISDN scheme must match between seeding and load generation:
// <dfsp><8-digit zero-padded index>, e.g. 20100000001 = party 1 at dfsp-201.
// This mirrors the bash scripts these replace (_rs/tuto3.md).

export const DFSPS = (__ENV.DFSPS || '201,202,203').split(',');
export const DFSP_DOMAIN = __ENV.DFSP_DOMAIN || 'dfsp.pj1.moja-do.delma.me';
export const N = Number(__ENV.N || 100);

// SDK scheme adapter outbound API (synchronous transfer journey)
export function outboundUrl(dfsp) {
  return `http://dfsp-${dfsp}.${DFSP_DOMAIN}:4001`;
}

// SDK test API (party repository backing the DFSP simulator)
export function testApiUrl(dfsp) {
  return `http://dfsp-${dfsp}.${DFSP_DOMAIN}:3004`;
}

export function msisdn(dfsp, i) {
  return `${dfsp}${String(i).padStart(8, '0')}`;
}

export function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}
