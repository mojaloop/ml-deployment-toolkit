# Upgrading

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Upgrading

**Audiences:** adopter (deploy)

Moving a running cluster to a new artifact version or a new infrastructure configuration. For how artifacts and reconciliation work, see [GitOps structure](../../architecture/gitops-structure.md).

- [Two kinds of upgrade](#two-kinds-of-upgrade)
- [Platform version](#platform-version)
- [Infrastructure](#infrastructure)
- [Migrating an existing environment](#migrating-an-existing-environment)
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

## Migrating an existing environment

An environment deployed before the two-stack split holds a single `artifacts/<env>/terraform/terraform.tfstate`. Splitting it is a one-time state operation — no VM is recreated ([ADR-015](../../architecture/decisions/015-two-stack-capability-config.md)).

```bash
tools/migrate-state.sh <env>            # dry run — prints every operation, changes nothing
tools/migrate-state.sh <env> --apply
```

Dry run is the default; `--apply` performs it. The script writes a timestamped backup of the original state before touching anything, then:

- copies the old state into `infra.tfstate` and `config.tfstate`, and `state rm`s each stack's resources from the other copy, so each stack owns exactly its own (nothing is destroyed — `state rm` only forgets);
- `state mv`s the six Kratos and Hydra secrets from their old individual addresses to their new `for_each` addresses. Without this Terraform destroys the old addresses and generates fresh values, and these are the values that must not rotate: a new `kratos_secrets_cipher` makes stored credential and recovery material undecryptable, and a new `hydra_secrets_system` invalidates every issued token and consent grant;
- warns when the environment's `cluster.name` differs from its directory name. Carry that value over verbatim — it is the external-dns record owner, the Vault backup prefix, and the VM name prefix, so changing it orphans DNS records and forces VM replacement.

Then rewrite `config.yaml` to the current schema and check the result before applying:

```bash
make validate ENV=<env>
make plan ENV=<env>
```

**The infra plan must show no changes.** If it plans to replace anything, stop — that is a mis-run migration, not an upgrade. The config plan is different: Kustomizations show as replacements because they moved from individual resources into a `for_each` map, which is safe, since Flux keeps reconciling from identical manifests.

**Keep the existing passwords.** Any generated secret whose UPPER_CASE name is present and non-empty in `.env` is used as-is instead of being generated, so an environment that writes its current values into `.env` keeps them — see [Configuration → Secrets](configuration.md#secrets). While the old cluster is still running, the values can be read from the `cluster-secrets` Secret in `flux-system`.

## Rolling back

| What | How |
|------|-----|
| Platform workloads | Set `artifact.version` back to the previous tag, `make apply-config` |
| Infrastructure | Revert the `config.yaml` change, `make plan-apply` |
| Data | Not a rollback — see [Recover → Restore](../recover/restore.md) |

Artifact rollback is clean because the artifact is immutable and content-addressed — the previous tag is the exact previous state. This is a reason to pin production: a rollback is just the tag the cluster was on before.

Data is different. A bad migration that has already written to the database is not undone by reverting the artifact — that is a restore, not a rollback, and it is why point-in-time recovery exists. See [Recover](../recover/backup.md).
