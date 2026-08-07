# 005 — FluxCD over ArgoCD for GitOps reconciliation

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 005 — FluxCD over ArgoCD for GitOps reconciliation

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform developer, adopter

## Context

The project needs a GitOps controller that reconciles cluster state from a declared source. Per ADR-001, the source of truth is an OCI registry (not a Git repository). The GitOps controller must natively support OCI artifacts as a source, enable per-environment customization without forking the artifact, and operate without requiring a Git server reachable from inside the cluster.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| ArgoCD | Large community, rich UI, mature ecosystem | Git-native design; OCI support is secondary (experimental Helm OCI, no native OCI source for manifests); requires Git for Application definitions; heavy footprint (server + repo-server + Redis + UI) |
| FluxCD (OCI source) | Native `OCIRepository` source, lightweight (single controller set), `postBuild` substitution for per-environment customization, Helm and Kustomize native | No built-in UI (requires Weave GitOps or similar), smaller community than ArgoCD |
| Manual kubectl apply | Simple, no dependencies | No reconciliation loop, drift detection, or self-healing; not GitOps |

## Decision

FluxCD with `OCIRepository` as the source type. Flux is installed via the `flux-operator` Helm chart (itself pulled from OCI), eliminating any Git dependency in the bootstrap chain. Per-environment customization is handled by Flux Kustomization `postBuild` substitution variables, injected from a Kubernetes ConfigMap and Secret created by Terraform.

## Consequences

- **No Git server needed.** The entire GitOps pipeline (bootstrap, source, reconciliation) operates against OCI registries only.
- **OCI artifact versioning.** Flux tracks the OCI tag and reconciles when a new version is pushed. Combined with ADR-007 (single artifact), this provides atomic updates.
- **`postBuild` substitution enables personalization without forking.** Environment-specific values (domain, IPs, credentials) are injected at reconciliation time via `${variable}` placeholders in the manifests.
- **No built-in UI.** Operational visibility requires CLI (`flux get`, `flux logs`) or an add-on UI. This is acceptable for infrastructure-focused teams.
- **Flux Operator install via Helm.** The Flux controllers themselves are installed as a Helm release, managed by Terraform's Helm provider. This avoids the circular dependency of needing Flux to install Flux.
