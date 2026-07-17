# k6 performance tests

Load tests for the switch, driven through the SDK scheme adapter outbound API on the
DFSP VMs (`dfsp-20x.dfsp.<domain>:4001`). One `POST /transfers` runs the full journey
(party lookup → quote → transfer) synchronously, so k6's `http_req_duration` is true
client-side end-to-end latency.

**SLO:** p99 < 1s e2e. Targets: 1 TPS today → 10 TPS on current hardware → 100/1000 TPS
on bigger hardware (revisit generator placement before those — a workstation over the
WAN won't hold 100+ TPS).

Runs from the workstation. The WAN hop is inside every latency number: treat absolute
values with care, comparisons between runs as the real signal.

## Prerequisites

- k6 ≥ 0.50 (`brew install k6`)
- Network reach to the DFSP VMs (port 3004/4001) and to `thanos.int.<domain>` (port 443)
- Seeded parties (below), after every environment rebuild

## Seeding

Registers `N` parties per DFSP in the SDK test API and batch-registers them in the ALS.
Idempotent. `N` must match between seeding and load runs.

```bash
k6 run seed.js          # N=100 per DFSP (default)
N=1000 k6 run seed.js
```

## Running

Metrics push to Thanos Receive so Grafana (`Mojaloop → Load Test (k6)` dashboard) shows
client-side latency next to switch internals. Set once per shell:

```bash
export K6_PROMETHEUS_RW_SERVER_URL=https://thanos.int.cc1.pj1.moja-do.delma.me/api/v1/receive
export K6_PROMETHEUS_RW_TREND_STATS='p(50),p(90),p(99),avg,max'
export K6_PROMETHEUS_RW_PUSH_INTERVAL=5s
# only if the gateway cert isn't trusted by your workstation:
export K6_PROMETHEUS_RW_INSECURE_SKIP_TLS_VERIFY=true
```

Thanos runs in the **ml-cc cluster**, so the hostname uses the cc domain
(`domain` in `config/environments/ml-cc/config.yaml`), not the switch domain.

**Soak** — regression baseline at a constant rate. p99 needs samples: at 1 TPS run
≥ 30m (~1800 samples), at 10 TPS ≥ 10m.

```bash
TESTID=soak-$(date +%Y%m%d-%H%M) \
  k6 run -o experimental-prometheus-rw transfers.js            # 1 TPS, 30m
TPS=10 DURATION=10m TESTID=soak10-$(date +%Y%m%d-%H%M) \
  k6 run -o experimental-prometheus-rw transfers.js
```

**Ramp** — find where p99 crosses the SLO. Steps through 1→2→4→6→8→10→12→15 TPS,
holding each for `STEP` (default 2m):

```bash
SCENARIO=ramp TESTID=ramp-$(date +%Y%m%d-%H%M) \
  k6 run -o experimental-prometheus-rw transfers.js
SCENARIO=ramp RAMP_STEPS=1,5,10,20 STEP=3m TESTID=... \
  k6 run -o experimental-prometheus-rw transfers.js
```

`TESTID` labels every pushed series; the Grafana dashboard filters on it. Convention:
`<scenario><tps?>-<yyyymmdd-hhmm>`.

## Variables

| Env var | Default | Meaning |
|---|---|---|
| `SCENARIO` | `soak` | `soak` or `ramp` |
| `TPS` | `1` | soak arrival rate (transfers/s) |
| `DURATION` | `30m` | soak duration |
| `RAMP_STEPS` | `1,2,4,6,8,10,12,15` | ramp TPS steps |
| `STEP` | `2m` | hold time per ramp step |
| `N` | `100` | parties per DFSP (must match seeding) |
| `TESTID` | — | run label pushed with all metrics |
| `DFSPS` | `201,202,203` | participating DFSPs |
| `DFSP_DOMAIN` | `dfsp.pj1.moja-do.delma.me` | DFSP host suffix |
| `REQUEST_TIMEOUT` | `5s` | per-transfer timeout (timeouts count as failures) |

## Thresholds (transfers.js)

- `http_req_duration: p(99) < 1000ms` — the SLO
- `http_req_failed: rate < 1%`
- `checks: rate > 99%` — transfers reaching `currentState=COMPLETED`
- `dropped_iterations: count < 1` — the generator kept pace; if this fires, the
  bottleneck is the load generator (VUs/workstation), not the switch

The `transfer_state` counter breaks results down by terminal state
(`COMPLETED` / `ERROR_OCCURRED` / `http_<code>` / `http_0` = timeout).

## Pre-flight (once per environment)

```bash
# Thanos reachable and switch handler metrics present?
curl -sk 'https://thanos.int.cc1.pj1.moja-do.delma.me/api/v1/query?query=moja_transfer_prepare_count' | jq '.data.result | length'

# DFSP outbound API reachable?
curl -s http://dfsp-201.dfsp.pj1.moja-do.delma.me:4001/ -o /dev/null -w '%{http_code}\n'
```

Verified 2026-07-02 from this workstation: both reachable, and all metrics the Load
Test dashboard queries (`moja_*` pipeline histograms, `kafka_consumergroup_lag`,
event loop lag, MySQL, node CPU) are present in Thanos for `cluster_name=ml-test`.
