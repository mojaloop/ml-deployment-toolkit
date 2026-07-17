# Platform Engineer Guide

[docs](../index.md) / Platform Engineer Guide

**Audiences:** platform engineer, system integrator

This guide covers building, extending, and publishing the ML Deployment Toolkit distribution. As a platform engineer, you maintain the Terraform modules in `src/`, the GitOps manifests in `gitops/`, and publish OCI artifacts that adopters consume.

System integrators who customize the distribution for specific adopters should also read this guide alongside the [adopter guide](../adopter/index.md).

For the architectural rationale behind these systems, see [architecture](../architecture/index.md).

## Contents

| Page | Description |
|------|-------------|
| [Building artifacts](building-artifacts.md) | OCI artifact build, publish, version, promote |
| [Adding providers](adding-providers.md) | How to add an infrastructure provider |
| [Adding services](adding-services.md) | How to add platform services, DNS providers, vendor services |
| [Module pipeline](module-pipeline.md) | Terraform module flow (config-loader -> provider -> flux) |
| [Known issues](known-issues.md) | Platform-level known issues (build, publish, Flux, CRDs) |
