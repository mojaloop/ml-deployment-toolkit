# `perf/` — Requirements

Status: agreed 2026-08-03.

## Context

`perf/` provides load generation and measurement for Mojaloop deployments. Its
users are whoever operates a switch — the maintainers of this toolkit, and
adopters running their own environments — for three distinct jobs:
**characterise** a deployment, **investigate** why it is slow, and **verify**
that a change helped.

The tool is deployment-agnostic. It makes no assumption about how DFSPs are
hosted, exposed, routed or named. Every endpoint is declared per participant;
nothing is derived from a hostname pattern, a port convention, an ingress
arrangement or a participant naming scheme.

---

## 1. Purpose

**1.1** Generate Mojaloop transfer load through DFSP SDK scheme-adapter
outbound APIs, and measure client-perceived latency and success.

**1.2** Serve characterisation, investigation and verification, which have
different needs and must not be collapsed into one another.

**1.3** Usable against any environment without editing a tracked file, and
**without cluster access**.

**1.4** Comparability across runs, environments and hardware is the primary
output. Absolute numbers are secondary — the generator's network path is
inside every latency figure.

**1.5** **Deployment-agnostic.** No requirement here may assume a particular
DFSP hosting model, ingress, port, TLS arrangement or naming convention.
Anything environment-specific is declared as configuration.

### Non-goals

Functional and conformance testing (the Testing Toolkit owns that); chaos or
failure injection; FX / cross-currency flows; distributed in-cluster
execution; checking seed state from inside a load run.

---

## 2. Workload model — three phases

**2.1** Each iteration executes three separately-timed phases against the SDK
scheme-adapter outbound API:

```
GET  {transfer}/parties/MSISDN/{msisdn}   -> discovery_time
POST {transfer}/quotes                    -> quote_time
POST {transfer}/simpleTransfers           -> transfer_time
                                             (ilpPacket + condition taken
                                              from the quote response)
                                          -> e2e_time = total
```

**2.2** These are the SDK scheme-adapter outbound API v2.0.0 contract. Driving
the phases separately is required: a single combined call yields one aggregate
number and no attribution, which cannot serve the investigation job in 1.2.

**2.3** A failing phase fails fast and is attributed to that phase.

**2.4** Load is arrival-rate driven (open model), so offered load stays
independent of system latency.

**2.5** Scenario shapes: constant-rate soak, stepped ramp, short smoke.

**2.6** Concurrency (VU allocation) is derived from target rate and observed
latency, never fixed constants.

**2.7** Per-request timeout is configurable and defaults **above** the
realistic worst case, so a timeout signals breakage rather than being routine.

---

## 3. Topology — `environments/<env>/perf-topology.yaml`

**3.1** One topology per environment, stored beside that environment's
deployment configuration. `ENV` selects it.

**3.2** Gitignored by the same rule as `config.yaml`, with a tracked
`.sample` in the sample environment as the documented schema. Adopters author
these, so the sample is a contract, not an example, and must be explicit
enough to copy and edit without reading the source.

**3.3** Participants are arbitrary in count (one or more) and identified by
their **full hub participant id**. No assumption that an id is numeric, that
participants share a prefix, or that the id appears anywhere in a URL.

**3.4** Each participant declares **five independently configurable URLs**,
because they may be served by different systems:

| Key | Purpose |
|---|---|
| `register_sim` | register one party in the participant's party repository |
| `register_als` | register a batch of identifiers in the scheme ALS |
| `discovery` | party lookup |
| `quotes` | quote request |
| `transfers` | transfer, carrying the quote's ILP packet and condition |

Each is complete — scheme, host, optional port, path. The tool constructs no
part of a URL. The one thing it appends is **data it already holds**: the
identifier on `discovery`, as `/<idType>/<idValue>`.

**3.5** Each participant declares an **MSISDN range** (`start` / `end`),
configured independently of its id. Deriving identifiers from a participant id
would constrain ids to whatever the identifier scheme allows, and is therefore
forbidden.

**3.6** Configuration is validated before load starts: endpoints reachable,
ids unique, ranges non-overlapping.

**3.7** A single-participant topology is either supported explicitly or
rejected with a clear error. It must never silently construct a malformed
request.

---

## 4. Scenarios — `environments/<env>/perf-scenarios/<name>.yaml`

**4.1** A scenario holds: rate, duration or ramp steps, **weighted
source→dest pairs**, thresholds, currency and amount. It does not name a
topology — `ENV` does.

**4.1.1** Pairs name participants explicitly. A scenario is therefore
environment-specific and lives with its environment. Expressing traffic as a
generic distribution was considered and rejected: it adds a second way to say
the same thing, and the pair counts in real use are small.

**4.2** Weighting is applied to **pairs**, not to participants. A pair
controls direction as well as volume, which is what exposes position-row
contention — uniform random pairing masks it.

**4.3** A scenario selects a subset of the topology's participants. The
topology declares what exists; the scenario decides what a given test uses.
Every referenced participant is validated before load starts.

**4.4** Scenarios are independent. Adding one never requires touching another.

---

## 5. Seeding — `make perf-seed`

**5.1** Seeding is a distinct responsibility. **The load run never checks seed
state.** With per-phase attribution, missing test data surfaces unambiguously
as discovery-phase failures.

**5.2** Idempotent and re-runnable.

**5.3** **Seeding verifies its own result.** This is the only place that
verification lives. Detection uses endpoints already in the topology:

```
GET {discovery}/MSISDN/<msisdn>   -> 200 | 404
```

One call is sufficient: a 200 proves the ALS resolved the identifier **and**
the owning participant's repository answered for it. A separate repository
check would be redundant. A missing party is a normal 404, never a hang.

Verification samples the range (start, middle, end, and points between)
rather than enumerating it, which distinguishes the failure modes that matter
— nothing registered, registered to a smaller range, wrong range entirely —
without a lookup per identifier. It is issued from a *different* participant
where one exists, since discovery is scheme-wide and asking a peer is closer
to what a transfer does.

**5.4** ALS registration uses the **API only** — `POST {register_als}/accounts`
with the batch array, which the SDK turns into a bulk ALS registration.
Registering by writing to a switch database directly is explicitly rejected:
it requires cluster access and credentials, and couples the tool to internal
schema.

**5.5** Party-repository registration is `POST {register_sim}` per party,
issued concurrently and resumable. There is no batch endpoint for this.

**5.6** Seeding reads the same topology as the run, so the MSISDN range and
identifier scheme cannot drift between them.

---

## 6. Health — `make perf-check`

**6.1** A standalone pre-flight command, never run automatically: Kafka lag on
**transfer-path topics only** (audit topics must not gate the check), pending
pods, and settle time since the last rollout.

**6.2** Post-run health delta — restart count, OOM kills, lag left behind — is
recorded **in the run report**. A disturbed run is a tainted *result*, not a
blocked one, so this belongs beside the numbers rather than in a gate.

**6.3** Both require a kubeconfig. Without one the run proceeds normally and
the report states that health was not observed.

---

## 7. Measurement

**7.1** Report **both** a compliance ratio (share of transactions within a
latency threshold) **and** percentiles. The ratio is the defensible gate — a
percentile near a threshold is interpolated inside whatever bucket spans it.
Percentiles are retained because they are the common currency for comparing
Mojaloop results.

The ratio is **counted during the run**, one vote per transaction per
threshold, because a percentile the generator computed internally cannot be
turned back into a share. Counting means the thresholds are fixed before the
run starts, so several are counted at once rather than one.

**7.1.1** The threshold set defaults to **0.01, 0.05, 0.1, 0.5, 1 and 5
seconds** — the boundaries common to `moja_*`, `mojaloop_connector_*` and
`traces_span_metrics_*`. Client-side and hub-side compliance are therefore
comparable at every value. The families diverge above 1s (2.0 against 2.5),
so no higher shared boundary exists. Overriding the set breaks the
comparison.

**7.2** The SLO **percentile and threshold are scenario parameters**. Neither
is hardcoded, and the reported percentile must be selectable to match whatever
a comparison target uses.

**7.3** Exactly one definition of the SLO exists in the codebase, and
documentation quotes it rather than restating it. It must be structurally
impossible for code and documentation to disagree.

**7.4** Report separately: per-phase latency; business failures; transport
failures; timeouts; and generator saturation.

**7.5** Generator saturation (dropped iterations) is called out prominently. A
run that dropped iterations did not apply the load it claimed, and its latency
figures are not comparable to one that did.

**7.6** Results break down per participant and per pair, not only in aggregate.

---

## 8. Observability

**8.1** Telemetry sinks are declared in the topology, since they are a
property of the environment rather than of a test, and are individually
optional — a run without them still produces a complete report.

**8.1.1** Metrics are pushed via Prometheus remote-write, tagged with the run
id.

**8.1.2** The tool's own run logs are pushed, labelled with the run id, so a
failed run's errors are searchable beside the switch's logs for the same
window.

**8.1.3** **No traces are pushed.** The tool emits no spans; it injects a
`traceparent` and the spans are produced by the hub and DFSP services and
collected by their own agents. A trace-store URL may be declared so a report
can link to where its traces landed, but declaring it must not cause any
export.

**8.2** Tag series by phase, sender and receiver, so per-DFSP dashboards can
correlate client-side and hub-side views.

**8.3** Optional `traceparent` injection with head sampling, so individual
transactions are retrievable in a trace store.

> **Constraint.** Any injected `tracestate` must not displace the Mojaloop
> Event SDK's own vendor entry. That entry is padded base64, which is invalid
> per W3C — `=` is forbidden in a tracestate value — so a conforming
> implementation drops it silently and any hub metric derived from it stops
> being emitted. A plain `key=value` entry with a W3C-legal value propagates
> safely; base64 does not.

**8.4** Emit run start/end markers usable as dashboard annotations.

**8.5** The run-id and metric-label conventions are a contract that dashboards
filter on.

---

## 9. Reports

**9.1** Results are per-run artefacts, stored outside both the code and the
environment so they survive an environment being rebuilt. They are committed.
No single append-only log accumulates them.

**9.2** Each run writes:

```
perf-result/<env>/<scenario>/<timestamp>/
  summary.json            machine-readable results
  scenario-snapshot.yaml  the test as run, overrides applied
  health.json             taint, restart delta, OOM kills
  notes.md                human analysis
```

**9.3** **A result never embeds a config.** It records which environment and
what test — never endpoints, hostnames or credentials. Those belong to the
environment's configuration and are managed like any other deployment config.

**9.3.1** Consequently a result is reproducible only in combination with that
environment's configuration — the same property `make plan-apply` has. This
is what makes results safe to commit.

**9.3.2** `scenario-snapshot.yaml` captures the test with overrides already
applied, so a run reproduces from its result rather than from shell history.

**9.4** Headline results are extracted automatically from the run. The tool
never writes a placeholder for a human to fill in later.

**9.5** `perf/INDEX.md` is generated from every `summary.json`.

**9.6** Run-over-run comparison is a first-class operation.

---

## 10. Execution

**10.1** Local execution only. No in-cluster runners.

**10.2** Config resolution is separate from execution: a wrapper resolves
topology, scenario and overrides into a single JSON document, mints the run
id, and collects health; k6 does load generation and writes its own summary.
No component downstream of resolution parses YAML or applies a default, which
is why the archived config reproduces the run exactly.

**10.4** Implemented with `bash`, `yq`, `jq` and `k6` — no additional runtime.
k6's own `handleSummary` writes the report, so no separate summary parser
exists.

**10.3** The report records where the generator ran and over what network
path, since that is inside every latency number.

---

## 11. Command surface

Driven through the repository's existing `make` interface, following its
`ENV=<name>` convention and `CHECK_ENV` guard style.

| Target | Variables | Purpose |
|---|---|---|
| `make perf-seed` | `ENV` (required) | register and verify parties |
| `make perf-check` | `ENV` (required) | readiness gate; needs a kubeconfig |
| `make perf-run` | `ENV` and `SCENARIO` (required), overrides | execute a scenario |
| `make perf-index` | — | regenerate `INDEX.md` |

```bash
make perf-seed  ENV=<env>
make perf-check ENV=<env>
make perf-run   ENV=<env> SCENARIO=<name>
make perf-run   ENV=<env> SCENARIO=<name> TPS=5 DURATION=10m
```

**11.1** `ENV` selects `environments/<ENV>/perf-topology.yaml` and the
scenarios beside it.

**11.2** `ENV` is **required** by every target, following the repository's
existing convention.

**11.3** Any scenario parameter is overridable as a make variable. Overrides
are recorded in `scenario-snapshot.yaml` (9.3.2), so a run is reproducible
from its result rather than from the command that produced it.

**11.4** Make is a thin wrapper over the resolver in 10.2. The underlying
entry point stays independently invocable, so the tool is not bound to this
repository's directory layout.

**11.5** Targets are listed in `make help` under their own heading.

---

## Accepted limitations

These follow from decisions taken deliberately, and are recorded so they are
not rediscovered as surprises.

- **Throughput ceiling.** Local-only generation caps achievable load well
  below what a distributed in-cluster generator reaches. High-TPS figures are
  out of reach for this tool as specified.
- **FX is a future breaking change.** No schema accommodation was made, so
  adding cross-currency support later will change a file adopters have already
  authored.
- **Missing test data surfaces as discovery failures** rather than being
  caught before load starts. Mitigated, not eliminated, by per-phase
  attribution.
- **MSISDN pool size affects results.** Too small a range causes identifier
  reuse within a run, which produces cache-level contention and failures
  unrelated to the system under test. Range sizing is a scenario concern.

---

## Decision log

| # | Decision | Rationale |
|---|---|---|
| 1 | Topology and scenarios in `environments/<env>/` | Configuration lives with the environment it describes and inherits its gitignore rule; `perf/` holds only code |
| 2 | Adopter-facing tool | Cluster access cannot be a prerequisite; client-side-only operation is mandatory, not a fallback |
| 3 | FX out of scope entirely | No schema accommodation made |
| 4 | Three-phase driver, k6 | Per-phase attribution is required for the investigation job |
| 5 | Results in `perf-result/<env>/<scenario>/<ts>/`, committed | Survives environment teardown; safe to commit because a result contains no config |
| 6 | Seeding is a separate responsibility; no seed check in the run | Do not mix responsibilities; seeding verifies itself |
| 7 | ALS registration via API only | Portability over speed; direct database writes require cluster access and internal schema knowledge |
| 8 | Local execution only | Scope; accepted cost is the throughput ceiling |
| 9 | `make perf-check` standalone; post-run taint in the report | Readiness is its own concern; health delta is part of the result |
| 10 | Per-run reports, generated index | Results stay attached to the configuration that produced them |
