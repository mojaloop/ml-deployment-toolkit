# Upgrading

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Upgrading

**Audiences:** adopter (deploy)

Moving a running cluster to a new artifact version or a new infrastructure configuration. For how artifacts and reconciliation work, see [GitOps structure](../../architecture/gitops-structure.md).

- [Two kinds of upgrade](#two-kinds-of-upgrade)
- [Platform version](#platform-version)
- [Infrastructure](#infrastructure)
- [Rolling back](#rolling-back)

## Two kinds of upgrade

| What changes | Driven by |
|--------------|-----------|
| Platform workloads (the OCI artifact) | `oci.repo.version`, reconciled by Flux |
| Infrastructure (nodes, topology, Flux itself) | `config.yaml`, applied by Terraform |

They are independent. A new artifact does not touch your nodes; a topology change does not touch your workloads.

## Platform version

How you upgrade depends on whether you pin the artifact or follow `latest`.

**Following `latest`** — nothing to do. Flux polls every 10 minutes and applies the new artifact when it appears. Watch it land:

```bash
kubectl get kustomizations -n flux-system
```

All should return to `Ready: True` within a few minutes.

**Pinned to a version** — bump the tag and apply:

```yaml
oci:
  repo:
    version: "v1.3.0"
```

```bash
make plan-apply ENV=<env>
kubectl get kustomizations -n flux-system
```

**Pin production.** Following `latest` means an upstream publish reaches your cluster with no warning and no window of your choosing. A pinned tag upgrades when you decide to.

Whatever the mode, confirm afterward that the Kustomizations settle back to Ready. A stalled one after an upgrade points at the earliest failing Kustomization — see [Troubleshooting](../operate/troubleshooting.md).

## Infrastructure

Changing node counts, sizing, VIPs, or the Flux version is a Terraform change.

```bash
make plan ENV=<env>      # review carefully — see below
make apply ENV=<env>
```

**Read the plan before applying.** Infrastructure changes can be disruptive in ways an artifact change never is — a sizing change can replace nodes, a VIP change moves the API endpoint. The plan tells you which; a workload-only change should show no node replacements.

Kubernetes and Talos versions are set centrally in the platform definitions, not in your `config.yaml`. Moving to a new Kubernetes version follows a new artifact from the platform team, then `make plan-apply`.

## Rolling back

| What | How |
|------|-----|
| Platform workloads | Set `oci.repo.version` back to the previous tag, `make plan-apply` |
| Infrastructure | Revert the `config.yaml` change, `make plan-apply` |
| Data | Not a rollback — see [Recover → Restore](../recover/restore.md) |

Artifact rollback is clean because the artifact is immutable and content-addressed — the previous tag is the exact previous state. This is a reason to pin production: a rollback is just the tag you were on before.

Data is different. A bad migration that has already written to the database is not undone by reverting the artifact — that is a restore, not a rollback, and it is why point-in-time recovery exists. See [Recover](../recover/backup.md).
