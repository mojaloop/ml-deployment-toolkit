# 024 — The provider boundary is a kubeconfig

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 024 — Narrow provider boundary

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer

> **Amended 2026-08-14 (config-layering refactor).** Generated output moved out of the clone: the contract path is now `../artifacts/<env>/kubernetes/kubeconfig`, rooted at `ARTIFACTS_ROOT` (default `../artifacts`, made absolute by the Makefile). The contract itself — provision a cluster, write the kubeconfig to that exact path — is unchanged, as is the vendor-Kustomization escape hatch.

## Context

Supporting more than one infrastructure provider invites sprawl: provider conditionals leaking into DNS, TLS, observability, and application layers until every feature is written N times. The distribution needed a rule for where provider-specific behaviour is allowed to live before a second and third provider made the question urgent.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Provider plugins with hooks into each layer | Each provider can tune everything | Every layer becomes provider-aware; N providers × M layers of surface |
| Conditionals in shared manifests | No structure to add | The sprawl this record exists to prevent |
| **One narrow contract: provision a cluster, return a kubeconfig** (chosen) | Everything above the kubeconfig is identical across providers | Anything a provider genuinely needs beyond that must fit one escape hatch |

## Decision

A provider module's entire contract is: **provision a working cluster and write a kubeconfig to `artifacts/<env>/kubernetes/kubeconfig`**. The one escape hatch is an optional vendor Kustomization (`gitops/<vendor>/`) for in-cluster components a platform cannot do without — Talos uses it for Cilium, OpenEBS, and LB-IPAM. Nothing in `gitops/platform/`, `gitops/hub*/`, or `gitops/tooling*/` is provider-aware.

## Consequences

- **Adding a provider touches no DNS, TLS, observability, or application code.** The shared layers cannot regress when a provider is added — they never see it.
- **The kubeconfig path is part of the contract.** The config stack reads that exact path; a module writing elsewhere breaks it silently.
- **The narrow contract is narrower than the wiring.** Registering a provider still means touching the schema enum, the provider blocks in the infra stack, and the config-loader's shape outputs — mechanical edits, but more than the one-module mental model suggests. The platform guide owns the full list.
- **A managed provider without an in-cluster data layer pushes the data question to configuration** — every data store must be bound to an external endpoint, enforced at plan time.
