# 003 — Thanos for metrics backend over Mimir and alternatives

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 003 — Thanos for metrics backend over Mimir and alternatives

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform developer, SRE

## Context

Mojaloop needs a Prometheus-compatible metrics backend with S3 as primary storage for durability and cost-effective long-term retention. The system is deployed on resource-constrained clusters where memory and CPU budgets are tight. The backend must be open-source friendly (license matters for adopters in regulated financial institutions).

## Alternatives considered

| Option | License | Storage model | Resource footprint | Verdict |
|--------|---------|---------------|-------------------|---------|
| Mimir | AGPL 3.0 | S3 primary | 7+ pods, ~3Gi RAM | Rejected — AGPL license creates friction for open-source adopters and regulated institutions |
| Thanos | Apache 2.0 | S3 primary | 4 pods, ~1.3Gi RAM | Selected |
| VictoriaMetrics | Apache 2.0 | S3 backup only (not primary) | 1 pod, ~512Mi RAM | Rejected — S3 is a backup target, not primary storage; data lives on local disk first |
| Cortex | Apache 2.0 | S3 primary | 1-6 pods | Rejected — in maintenance mode since the Mimir fork; no active development |
| Prometheus (standalone) | Apache 2.0 | S3 backup only (via Thanos sidecar) | 1 pod | Rejected — no native S3 primary storage; retention limited to local disk |

## Decision

Thanos as the metrics backend. It provides S3 as primary storage (not a backup tier), carries the Apache 2.0 license (no adoption friction), is a CNCF Incubating project, and fits within cluster resource budgets. The architecture uses push-based ingestion via Prometheus `remote_write` to Thanos Receive, avoiding the need for a Thanos sidecar on every Prometheus instance.

Components deployed: Thanos Receive (ingestion), Thanos Store Gateway (S3 query), Thanos Compactor (downsampling/retention), Thanos Query (unified query frontend). Manifests are generated from the upstream kube-thanos Jsonnet library (no official Helm chart exists).

## Consequences

- **S3 as durable primary storage.** Metrics survive pod restarts and node failures without relying on persistent volumes for long-term data.
- **Apache 2.0 license.** No AGPL concerns for adopters distributing or modifying the deployment.
- **Resource efficient.** 4 pods at ~1.3Gi total RAM fits resource-constrained environments.
- **~2h data loss window.** If Thanos Receive crashes, data in its local WAL (not yet shipped to S3) can be lost. Acceptable for operational metrics; not suitable for financial audit logs.
- **Jsonnet-based manifests.** No Helm chart means kube-thanos Jsonnet must be rendered and maintained, which is less familiar than Helm for most teams.
- **Config variable named `mimir_url`.** The Flux substitution variable is still `${mimir_url}` for backwards compatibility with existing Prometheus remote_write configs, despite pointing to Thanos Receive.
