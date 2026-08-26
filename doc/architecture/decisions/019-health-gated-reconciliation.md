# 019 — Health-gated reconciliation ordering

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 019 — Health-gated reconciliation

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer, adopter

## Context

Flux `dependsOn` orders when Kustomizations are *applied*, not when their workloads are *usable*. That distinction is fatal on a Hub: the MySQL operator creates database users asynchronously, minutes after the cluster object exists, and a Mojaloop migration job that starts before its user exists fails with access denied. The same shape recurs across the stack — webhooks that reject resources until their Deployment is ready, Kafka topics created against a cluster still forming, auth services migrating against databases still provisioning.

The failures are all races: each component works, but only if something upstream is not merely applied but healthy. This record documents the gating design retroactively; it has been in place since the reconciliation graph was built.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Retry until it works (Helm remediation alone) | No graph to maintain | Retries mask real failures, burn install attempts on races, and converge slowly and noisily |
| Init containers / wait scripts per workload | Local to each consumer | The wait logic multiplies across charts the distribution does not own; upstream charts cannot be edited |
| Gate on object existence | Simple checks | Existence is the wrong signal — the PXC cluster object exists minutes before its users do |
| **Gate on reported health** (chosen) | The operator that owns the resource declares readiness; consumers start exactly when the dependency is usable | Convergence is serialized; an early failure blocks everything downstream |

## Decision

The Kustomization chain — `platform → dns → platform-config → vendor → role` — gates each link on the *health* of what the previous one produced, not on its application:

- Operator webhooks (cert-manager, external-secrets) gate on their Deployments becoming ready before anything submits resources to them.
- `hub-data-mysql` gates on the Percona cluster reporting `status.state == ready` — the state the operator sets only after users exist.
- `hub-data-kafka` and `hub-data-mongodb` gate on their operators' CR health checks. Redis has no CR status worth gating on and is applied ungated.
- `hub-vault` gates on `hub-data-mysql`; `hub-iam` gates on `hub-vault`; `hub-app` gates on `hub-iam-config` and the data stores.

Health is expressed with `healthCheckExprs` on CR status fields where a status exists, and standard Deployment readiness elsewhere. Helm remediation retries remain as a second line, absorbing whatever the gates cannot see.

## Consequences

- **A Hub converges serially and takes longer than a Tooling Cluster** — the data layer must report ready before auth starts, and auth before the applications.
- **An early failure blocks everything downstream.** `flux get kustomizations` read top-to-bottom shows the earliest failing link; that is always the one to debug.
- **The old migration-race failure class is gone.** Fresh deployments install Mojaloop on the first attempt; the corresponding known-issue entry was retired.
- **Gates are per-resource opt-in.** A new operator-managed store must declare a health expression, or its consumers inherit the race this design exists to prevent.
- **Redis is ungated.** Nothing waits on it; a Redis-dependent workload that cannot tolerate a briefly absent Redis must handle that itself.
