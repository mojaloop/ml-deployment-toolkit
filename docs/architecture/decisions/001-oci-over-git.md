# 001 — OCI-based distribution over Git-based GitOps

[docs](../../index.md) / [architecture](../index.md) / [decisions](./) / 001 — OCI-based distribution over Git-based GitOps

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform engineer, adopter

## Context

Mojaloop adopters include financial institutions and central banks operating in regulated, air-gapped, or restricted-connectivity environments. A GitOps distribution model that depends on Git repository access from inside the cluster creates problems: Git servers must be reachable, Git credentials must be provisioned in every cluster, and artifact versioning is tied to commit SHAs rather than explicit release versions.

OCI registries (Harbor, GHCR, ECR) are already required infrastructure for container images. Using the same registry for GitOps artifacts eliminates a separate dependency.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Git repo (ArgoCD/Flux Git source) | Simple setup, native Git history | Requires Git access from clusters, credential management per cluster, no air-gap without Git mirror |
| OCI artifact (Flux OCI source) | Air-gap native, single artifact versioning, reuses existing registry infra | Requires OCI registry (Harbor/GHCR/ECR), less familiar workflow |
| Helm chart repo | Familiar Helm tooling, versioned releases | Only works for Helm charts, not raw Kustomize; forces Helm wrapping for everything |

## Decision

OCI artifact as the sole distribution mechanism. The entire `gitops/` directory is published as a single OCI artifact to an OCI registry (Harbor for on-prem, GHCR/ECR for cloud). FluxCD pulls from the OCI registry using `OCIRepository` as its source. Versioning uses Git SHA with a `latest` tag alias.

## Consequences

- **Enables air-gapped operation.** Clusters only need access to their OCI registry (Harbor), not to any Git server or external network.
- **Single artifact versioning.** All kustomization paths (platform, vendor, role-specific) share one version tag, guaranteeing compatibility.
- **No Git credentials in clusters.** OCI registry credentials (already needed for container images) are the only credential type required.
- **Requires OCI registry infrastructure.** The Control Center must run Harbor (on-prem) or have access to a managed OCI registry (cloud). This is already a requirement for container image distribution.
- **Build step required.** `make push-gitops` must be run to publish changes, adding a step compared to Git-based GitOps where pushing to a branch triggers reconciliation.
