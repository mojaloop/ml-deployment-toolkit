# 007 — Single OCI artifact with multiple kustomization paths

[docs](../../index.md) / [architecture](../index.md) / [decisions](./) / 007 — Single OCI artifact with multiple kustomization paths

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform engineer

## Context

The `gitops/` directory contains multiple kustomization roots spanning platform services, DNS provider config, vendor-specific resources (Talos, AWS, GCP), role-specific services (Control Center, App Environment), and application layers. These layers have interdependencies (e.g., platform-config depends on platform, env-app depends on env-data) and must be version-coherent -- mixing platform v1.2 with env-app v1.3 can cause breakage.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| One OCI artifact per layer | Independent versioning, smaller artifact per pull, can update layers independently | Version matrix explosion, no guaranteed compatibility between layers, complex Flux config with multiple OCIRepositories |
| Single OCI artifact with all paths | Atomic versioning, single publish step, one OCIRepository in Flux, guaranteed compatibility | Larger artifact size, all-or-nothing updates, any change triggers full artifact rebuild |

## Decision

Single OCI artifact containing the entire `gitops/` directory. Flux Kustomizations select specific paths within the artifact based on environment configuration (provider, DNS provider, cluster role). The `flux-config` Terraform module creates the appropriate set of Kustomizations for each environment.

Dependency chain within the artifact: `platform` -> `dns/{provider}` -> `platform-config` -> vendor (`talos`|`aws`|`gcp`) -> role-specific (`cc`|`cc-config`|`cc-routes`|`env`|`env-data`|`env-auth`|`env-app`).

## Consequences

- **Atomic versioning.** All kustomization paths from one tag are guaranteed compatible. No version matrix to manage.
- **Single publish step.** `make push-gitops` publishes one artifact. No coordination needed between multiple artifact builds.
- **Simplified Flux config.** One `OCIRepository` resource per cluster, with multiple `Kustomization` resources selecting paths within it.
- **Larger artifact size.** Every cluster pulls paths it does not use (e.g., an AWS environment pulls Talos manifests). The overhead is negligible (YAML manifests are small) and OCI layer caching mitigates repeated pulls.
- **All-or-nothing updates.** Cannot update only the platform layer without also updating the app layer. This is intentional -- it forces version coherence and prevents partial upgrades.
