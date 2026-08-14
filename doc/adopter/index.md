# Adopter Guide

[doc](../index.md) / Adopter

**Audiences:** adopter (deploy, recover, operate)

The adopter runs a Hub. This guide takes an adopter from an empty Proxmox cluster to a running Mojaloop switch, keeps it recoverable, and keeps it healthy.

The adopter configures one environment directory — `config.yaml`, `.env`, `placement.yaml`, `proxmox/proxmox.yaml`, and optional `values/` and `patches/` — and runs Terraform through Make, never forking the distribution or editing the clone. The environment lives at `../environments/<env>/`, a sibling of the clone and its own git repository, created by copying a reference environment out of `examples/environments/` ([Configuration → Environment layout](deploy/configuration.md#environment-layout)). Everything specific to a deployment lives in the adopter's own configuration. Changing the distribution itself is the [Integrator](../integrator/index.md) guide.

## Three journeys

```mermaid
flowchart LR
    d["Deploy"] --> o["Operate"]
    o -.->|"when something breaks"| r["Recover"]
    r -.-> o
```

| Journey | When it applies | Start |
|---------|-------------------|-------|
| **[Deploy](deploy/prerequisites.md)** | Standing up a Tooling Cluster or a Hub | [Prerequisites](deploy/prerequisites.md) |
| **[Operate](operate/monitoring.md)** | Running it day to day — watching, diagnosing | [Monitoring](operate/monitoring.md) |
| **[Recover](recover/backup.md)** | Restoring data, or rebuilding after loss | [Backups](recover/backup.md) |

## Deploy

Getting from nothing to a running switch.

| Page | Covers |
|------|--------|
| [Prerequisites](deploy/prerequisites.md) | Tools, accounts, and credentials needed first |
| [Provider setup](deploy/provider-setup.md) | Preparing Proxmox and the DNS zone |
| [Configuration](deploy/configuration.md) | The environment directory — `config.yaml`, `.env`, the provider sidecar files, overrides — and the vocabulary mapping |
| [Deployment](deploy/deployment.md) | The deploy workflow, commands, and verification |
| [Deploy a Tooling Cluster](deploy/tooling-cluster.md) | Role `tooling` — registry, secrets, observability backend |
| [Deploy a Hub](deploy/hub.md) | Role `hub` — the Mojaloop switch |
| [Upgrading](deploy/upgrading.md) | Moving to a new artifact or infrastructure change |
| [Known issues](deploy/known-issues.md) | Deployment-time issues and workarounds |

Deploy the Tooling Cluster first if using one, then Hubs. A single Hub can run without a Tooling Cluster by pulling from a public registry.

## Operate

Keeping a running Hub healthy.

| Page | Covers |
|------|--------|
| [Monitoring](operate/monitoring.md) | Dashboards, what to watch, log and metric queries |
| [Troubleshooting](operate/troubleshooting.md) | Symptom-first diagnosis |
| [Onboarding participants](operate/onboarding-participants.md) | The Hub-side onboarding procedure |
| [Known issues](operate/known-issues.md) | Runtime issues and workarounds |

## Recover

Restoring data and rebuilding after loss. Read this **before** it is needed — the first recovery should not be the first read.

| Page | Covers |
|------|--------|
| [Backups](recover/backup.md) | What is backed up, what is not, and what the adopter must back up |
| [Restore](recover/restore.md) | Restoring MySQL, MongoDB, and Vault |
| [Disaster recovery](recover/disaster-recovery.md) | Rebuilding a cluster, and the material no rebuild can do without |

## Before starting

Knowing two things about this toolkit going in saves time:

**Namespaces do not match intuition.** A `kubectl` command against the wrong namespace returns an empty list that looks like success — the namespace map is in [System overview](../architecture/system-overview.md#what-a-hub-runs).

**A Hub takes time to converge.** The reconciliation chain waits for each layer to be healthy before starting the next ([ADR-019](../architecture/decisions/019-health-gated-reconciliation.md)). "Looks stuck" for several minutes after `make apply` is usually normal. See [Reconciliation order](../architecture/system-overview.md#reconciliation-order).
