# 006 — Talos Linux for on-prem Kubernetes

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 006 — Talos Linux for on-prem Kubernetes

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform developer, infrastructure engineer

> Still accepted. Since [ADR-015](015-two-stack-capability-config.md) the provisioning pipeline described here is the **infra stack** (`src/infra`); the machine-config patches live in `config/patches/talos/`, and node counts and shapes come from a capacity template rather than a per-provider profile.

## Context

On-prem Mojaloop deployments need a Kubernetes distribution that can be provisioned and managed declaratively via Terraform, without requiring SSH access or manual node configuration. The OS and Kubernetes lifecycle should be API-driven to match the infrastructure-as-code model used for cloud providers (EKS, DOKS). Immutability is desirable to reduce configuration drift and security surface area.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| kubeadm | Standard Kubernetes tooling, widely understood | SSH-based provisioning, mutable OS, manual upgrade process, configuration drift risk |
| k3s | Lightweight, single binary, fast bootstrap | Mutable OS, SSH-based management, designed for edge/dev rather than production financial workloads |
| RKE2 | Rancher ecosystem, FIPS-compliant option, CIS hardened | Tied to Rancher ecosystem, SSH-based provisioning, mutable OS |
| Talos Linux | Immutable OS, API-only management (no SSH/shell), declarative YAML config with layered patches, Terraform provider | Two-phase CNI deployment required, smaller community than kubeadm, steeper learning curve |

## Decision

Talos Linux for all on-prem Kubernetes clusters (Proxmox). Machine configurations are declarative YAML with layered patches applied via the Talos Terraform provider. The provisioning pipeline is: `talos-gen-config` (generate machine configs with patches) -> `proxmox-vm` (create VMs, attach machine config via cloud-init) -> `talos-bootstrap` (bootstrap cluster, health check, write kubeconfig).

## Consequences

- **No SSH, no shell.** All node management is via the Talos API. This eliminates an entire class of security concerns (SSH key management, shell escape vulnerabilities) but requires Talos-specific tooling (`talosctl`).
- **Declarative, layered configuration.** Machine configs use a base + patches model (`patch-cilium-install.yaml`, `patch-openebs.yaml`, `patch-vip.yaml.tpl`, `patch-allow-scheduling-on-cp.yaml`), enabling topology-specific customization without duplicating full configs.
- **Two-phase Cilium deployment.** Talos cannot run Helm during node boot. Cilium must be pre-rendered and applied via `extraManifests` (Phase 1), then adopted by Flux HelmRelease for ongoing management (Phase 2). See ADR-002.
- **Immutable infrastructure.** OS updates are atomic image replacements, not package upgrades. No configuration drift between nodes.
- **Terraform-native lifecycle.** Cluster creation, scaling, and upgrades are all `make plan-apply` operations, consistent with cloud provider workflows.
- **Node changes are infra-stack changes.** Since ADR-015 a config-only edit runs through `make apply-config` and cannot reach a node; anything that alters machine config or topology is a full `make plan-apply`.
- **VIP for API endpoint.** On-prem clusters use a floating Virtual IP for the Kubernetes API endpoint, configured via Talos machine config patches.
