# Upgrading

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Upgrading

**Audiences:** adopter (deploy)

Moving a running cluster to a new artifact version or a new infrastructure configuration. For how artifacts and reconciliation work, see [GitOps structure](../../architecture/gitops-structure.md).

- [Two kinds of upgrade](#two-kinds-of-upgrade)
- [Platform version](#platform-version)
- [Infrastructure](#infrastructure)
- [Rolling back](#rolling-back)

## Two kinds of upgrade

| What changes | Driven by | Applied with |
|--------------|-----------|--------------|
| Platform workloads (the OCI artifact) | `artifact.version`, reconciled by Flux | `make apply-config` |
| Infrastructure (nodes, topology, Flux itself) | `config.yaml`, applied by Terraform | `make plan-apply` |

They are independent. A new artifact does not touch the nodes; a topology change does not touch the workloads. Because the artifact version belongs to the config stack, bumping it is the fast path — seconds, and no infrastructure plan to read.

## Platform version

The upgrade path depends on whether the artifact is pinned or follows `latest`.

**Following `latest`** — nothing to do. Flux polls every 10 minutes and applies the new artifact when it appears. Watch it land:

```bash
kubectl get kustomizations -n flux-system
```

All should return to `Ready: True` within a few minutes.

**Pinned to a version** — bump the tag and apply:

```yaml
artifact:
  version: "v1.3.0"
```

```bash
make apply-config ENV=<env>
kubectl get kustomizations -n flux-system
```

**Pin production.** Following `latest` means an upstream publish reaches the cluster with no warning and no window of the adopter's choosing. A pinned tag upgrades when the adopter decides.

Whatever the mode, confirm afterward that the Kustomizations settle back to Ready. A stalled one after an upgrade points at the earliest failing Kustomization — see [Troubleshooting](../operate/troubleshooting.md).

## Infrastructure

Changing node counts, the `template`, VIPs, the placement map, or the Flux version is an infra-stack change.

```bash
make plan-infra ENV=<env>      # review carefully — see below
make apply-infra ENV=<env>
make apply-config ENV=<env>    # push any config that moved with it
```

**Read the plan before applying.** Infrastructure changes can be disruptive in ways a config change never is — a `template` change can replace nodes, a VIP change moves the API endpoint. The plan shows which; a workload-only change should show no node replacements. A change that touches only config-stack inputs never needs this plan at all, which is the point of the split ([ADR-015](../../architecture/decisions/015-two-stack-capability-config.md)).

Kubernetes and Talos versions are set centrally in the platform definitions, not in the environment's `config.yaml`. Moving to a new Kubernetes version follows a new artifact from the platform team, then `make plan-apply`.

## Rolling back

| What | How |
|------|-----|
| Platform workloads | Set `oci.repo.version` back to the previous tag, `make plan-apply` |
| Infrastructure | Revert the `config.yaml` change, `make plan-apply` |
| Data | Not a rollback — see [Recover → Restore](../recover/restore.md) |

Artifact rollback is clean because the artifact is immutable and content-addressed — the previous tag is the exact previous state. This is a reason to pin production: a rollback is just the tag the cluster was on before.

Data is different. A bad migration that has already written to the database is not undone by reverting the artifact — that is a restore, not a rollback, and it is why point-in-time recovery exists. See [Recover](../recover/backup.md).
