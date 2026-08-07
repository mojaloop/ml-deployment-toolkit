# 023 — Tail-based trace sampling

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 023 — Tail-based trace sampling

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer, adopter (operate)

## Context

Tracing every transfer end-to-end is affordable at lab load and ruinous at production TPS. Sampling is unavoidable — but the traces worth keeping are exactly the ones a naive sampler discards: the errors and the slow outliers. Head sampling decides at the root span, before knowing how the trace ends, so it keeps a flat percentage of everything and loses most of the interesting tail.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Head sampling at N% | Cheap, stateless | Keeps N% of errors too — the traces needed most are the least likely to survive |
| Keep everything, short retention | No decisions to make | Storage scales with TPS, not with usefulness; still unaffordable at target load |
| **Tail sampling** (chosen) | Decides after the trace completes: keep by outcome | The collector must buffer open traces; the decision window is a real parameter with real failure modes |

## Decision

The trace branch bound for Tempo is tail-sampled in Alloy: **every error trace** is kept, **every trace slower than 1 s** — the p99 SLO — is kept, and **10% of the remainder**. The decision window is 30 seconds, sized for Mojaloop's asynchronous callback flows: a shorter window splits one logical transfer into fragments sampled independently.

Span metrics and the service graph are computed from the stream **before** sampling, so request counts and latency percentiles are exact regardless of what the sampler keeps.

## Consequences

- **A missing trace for an unremarkable transfer is sampling, not an outage.** Errors and SLO breaches are always retained.
- **Metrics are undistorted** — percentiles come from the full stream, not from the sampled 10%.
- **The 30 s decision window is load-bearing.** Shrinking it to save collector memory silently fragments async traces; that failure mode was observed before the window was widened.
- **Collector memory scales with open-trace volume.** At higher TPS the window and the buffer limits need revisiting together.
