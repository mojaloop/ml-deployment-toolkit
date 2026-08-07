# 012 — TPS-based sizing profiles

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 012 — TPS-based sizing profiles

**Date:** 2026-04-02
**Status:** superseded by [015](015-two-stack-capability-config.md)
**Audiences:** architect, platform developer, adopter (deploy)

> **Superseded in mechanism, kept in principle.** [ADR-015](015-two-stack-capability-config.md) replaced the per-provider profile files described below with a provider-independent capacity template (`config/templates/{role}/{tier}.yaml`) plus a thin per-provider mapping, and renamed the `config.yaml` key from `profile:` to `template:`. What this record decided — that one named tier bundles infrastructure topology, application replicas, and data-layer tuning, and that Hub tiers are named for the transaction rate they sustain — still holds. Read it for the reasoning; read ADR-015 for the current layout.

## Context

Deploying Mojaloop required the deployer to understand infrastructure topology names (e.g. `h2c1w3`) and had no connection between infrastructure sizing and application-level scaling. Application replicas, Kafka partitions, and MySQL tuning were hardcoded in gitops manifests. This meant deployers needed expert knowledge of both infrastructure and Mojaloop internals.

Performance testing showed that four dimensions must scale together for a given throughput target: the infrastructure provider, infrastructure topology, application horizontal scaling, and data layer tuning. Scaling any one without the others creates bottlenecks.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Per-template folder with all sizing definitions | Fully explicit per topology | Heavy duplication across templates; every new service needs entries in all folders; doesn't compose across providers |
| Abstract scaling profiles (t-shirt sizes) decoupled from infra | DRY; cross-provider | Adds indirection; still needs provider-specific infra template reference |
| **TPS profiles per provider** (chosen) | Single file bundles all four dimensions; provider-specific; deployer picks one number; no duplication | One profile per TPS tier per provider (manageable) |

## Decision

Sizing profiles replace `deployment-templates.yaml`. Each profile lives under `config/providers/{provider}/profiles/{role}/{profile}.yaml` and bundles:

- **Infrastructure topology** (inlined, was `deployment-templates.yaml`)
- **Application horizontal scaling** (pod replica counts)
- **Data layer tuning** (Kafka partitions, MySQL buffer pool, connections, storage)

Profile files are organized by cluster role:
- `hub/` — TPS-driven (`tps-1`, `tps-500`, `tps-2000`)
- `tooling/` — Operations-scale-driven (`small`, `medium`, `large`)
- `bare/` — Lightweight infra-only (`small`)

The deployer's `config.yaml` changes from `template: "h2c1w3"` to `profile: "tps-1"`. The config-loader module resolves the profile path from `provider + role + profile` and outputs infrastructure topology (to provider modules) plus app/data/tooling variables (to flux-config, which merges them into the `cluster-config` ConfigMap for Flux postBuild substitution).

Available tiers, in their current form: [Provider model](../provider-model.md#deployment-templates)

## Consequences

- Deployers choose a single TPS target instead of learning infrastructure template names
- Platform team maintains tested, coherent profiles per provider — all four scaling dimensions are co-designed
- Profile variables flow through the existing Flux substitution pipeline (ConfigMap) — no new mechanisms
- `deployment-templates.yaml` files are retired; infrastructure topology is inlined in profiles
- Adding a new TPS tier requires one new YAML file per provider — profiles are self-contained
- Per-topic Kafka partition control requires KafkaTopic CRs (future work for tps-500+); currently uses `num.partitions` cluster default
