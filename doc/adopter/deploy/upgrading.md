# Upgrading

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Upgrading

**Audiences:** adopter (deploy)

Moving a running cluster to a new artifact version or a new infrastructure configuration. For how artifacts and reconciliation work, see [GitOps structure](../../architecture/gitops-structure.md).

- [Two kinds of upgrade](#two-kinds-of-upgrade)
- [Platform version](#platform-version)
- [Infrastructure](#infrastructure)
- [Migrating an existing environment](#migrating-an-existing-environment)
- [Migrating across the config-layering release](#migrating-across-the-config-layering-release)
- [Rolling back](#rolling-back)

## Two kinds of upgrade

| What changes | Driven by | Applied with |
|--------------|-----------|--------------|
| Platform workloads (the OCI artifact) | `artifact.version`, reconciled by Flux | `make apply-config` |
| Infrastructure (nodes, topology, Flux itself) | `config.yaml`, applied by Terraform | `make plan-apply` |

They are independent. A new artifact does not touch the nodes; a topology change does not touch the workloads. Because the artifact version belongs to the config stack, bumping it is the fast path — seconds, and no infrastructure plan to read.

## Platform version

**`artifact.version` is always a pinned `vX.Y.Z` tag** — the schema rejects `latest`, so an upstream publish can never reach a cluster unbidden. Upgrading is a deliberate bump, made when the adopter decides.

A DTK release pins the Terraform code, the gitops content, and the OCI artifact to each other, so the clone and the environment move together:

1. **Check out the new release tag in the clone.** An upgrade is a checkout, never a rebase — the clone is pristine and holds no adopter changes:

   ```bash
   git checkout v0.19.0
   ```

2. **Diff the reference environment across the hop.** The samples under `examples/environments/` are the reference an environment was copied from; the diff between two tags is exactly what changed in the environment surface — new keys, renamed files, changed conventions:

   ```bash
   git diff v0.18.0..v0.19.0 -- examples/environments/
   ```

   Apply what the diff shows to the environment's own files, and read the release notes for anything the samples cannot express.

3. **Update the environment.** Bump `artifact.version` — and `dtk_version`, when the environment pins it — in `config.yaml`, then commit to the environment's repository.

4. **Validate and apply:**

   ```bash
   make validate ENV=<env>
   make apply-config ENV=<env>
   kubectl get kustomizations -n flux-system
   ```

   Use `make plan-apply` instead when the release notes call out infrastructure changes ([Infrastructure](#infrastructure)).

**One release at a time.** Walk through each intermediate release rather than jumping several at once: each hop's reference-environment diff is small enough to act on, and each release's migration steps apply exactly once. A multi-release jump compounds every change into one diff and one apply, with no way to tell which hop broke.

**The `dtk_version` assert keeps the pair honest.** With `dtk_version` pinned, the plan fails when the clone is not checked out at that exact tag — a mismatch fails, it does not warn ([Configuration → Rules that fail at plan time](configuration.md#rules-that-fail-at-plan-time)). That is the guard against upgrading the environment and the clone separately.

Confirm afterward that the Kustomizations settle back to Ready. A stalled one after an upgrade points at the earliest failing Kustomization — see [Troubleshooting](../operate/troubleshooting.md).

## Infrastructure

Changing node counts, the `template`, VIPs, the mapping in `placement.yaml`, or the Flux version is an infra-stack change.

```bash
make plan-infra ENV=<env>      # review carefully — see below
make apply-infra ENV=<env>
make apply-config ENV=<env>    # push any config that moved with it
```

**Read the plan before applying.** Infrastructure changes can be disruptive in ways a config change never is — a `template` change can replace nodes, a VIP change moves the API endpoint. The plan shows which; a workload-only change should show no node replacements. A change that touches only config-stack inputs never needs this plan at all, which is the point of the split ([ADR-015](../../architecture/decisions/015-two-stack-capability-config.md)).

Kubernetes and Talos versions are set centrally in the platform definitions, not in the environment's `config.yaml`. Moving to a new Kubernetes version follows a new artifact from the platform team, then `make plan-apply`.

## Migrating an existing environment

An environment deployed before the two-stack split holds a single `terraform.tfstate` under its artifacts directory. Splitting it is a one-time state operation — no VM is recreated ([ADR-015](../../architecture/decisions/015-two-stack-capability-config.md)). The split lands directly in the current layout: the script reads and writes `../artifacts/<env>/state/`, so a migrated environment comes out on the `state/` + `plans/` arrangement with nothing further to move.

```bash
# Run from the DTK tag that shipped the split (the script was removed once the
# migration window closed — matched versions only: check out that tag first):
tools/migrate-state.sh <env>            # dry run — prints every operation, changes nothing
tools/migrate-state.sh <env> --apply
```

Dry run is the default; `--apply` performs it. The script writes a timestamped backup of the original state before touching anything, then:

- copies the old state into `infra.tfstate` and `config.tfstate`, and `state rm`s each stack's resources from the other copy, so each stack owns exactly its own (nothing is destroyed — `state rm` only forgets);
- `state mv`s the six Kratos and Hydra secrets from their old individual addresses to their new `for_each` addresses. Without this Terraform destroys the old addresses and generates fresh values, and these are the values that must not rotate: a new `KRATOS_SECRETS_CIPHER` makes stored credential and recovery material undecryptable, and a new `HYDRA_SECRETS_SYSTEM` invalidates every issued token and consent grant;
- warns when the environment's `cluster.name` differs from its directory name. Carry that value over verbatim — it is the external-dns record owner, the Vault backup prefix, and the VM name prefix, so changing it orphans DNS records and forces VM replacement.

Then rewrite `config.yaml` to the current schema and check the result before applying:

```bash
make validate ENV=<env>
make plan ENV=<env>
```

**The infra plan must show no changes.** If it plans to replace anything, stop — that is a mis-run migration, not an upgrade. The config plan is different: Kustomizations show as replacements because they moved from individual resources into a `for_each` map, which is safe, since Flux keeps reconciling from identical manifests.

**Keep the existing passwords.** Any generated secret whose UPPER_CASE name is present and non-empty in `.env` is used as-is instead of being generated, so an environment that writes its current values into `.env` keeps them — see [Configuration → Secrets](configuration.md#secrets). While the old cluster is still running, the values can be read from the `cluster-secrets` Secret in `flux-system`.

## Migrating across the config-layering release

An environment deployed before the config-layering release ([design record](../../architecture/config-layering-design.md)) lived *inside* the clone and used the old configuration surface. Bringing it forward is a one-time restructure:

1. **Move the environment out of the clone.** Its home is `../environments/<env>/`, a sibling of the clone, as its own git repository ([Configuration → Environment layout](configuration.md#environment-layout)):

   ```bash
   mv environments/<env> ../environments/<env>
   ```

   Compare it against the current samples in `examples/environments/` — in particular, take the `.gitignore` that keeps `.env` out of the repository — then `git init` and commit.

2. **Split the provider facts out of `config.yaml`.** The `infra.proxmox.placement`, `infra.proxmox.network_bridge`, and `infra.proxmox.storage` keys are gone: their values move to `placement.yaml` and `proxmox/proxmox.yaml` beside the config. The `infra.talos.nameservers` and `infra.talos.ntp_servers` keys are gone too — their values move to `talos.yaml` beside the config ([Configuration → Environment layout](configuration.md#environment-layout)). Delete `cluster.gateway_class_name` — the GatewayClass is the provider's `P_GATEWAY_CLASS` now — and pin `artifact.version` to an exact `vX.Y.Z` tag, since `latest` is rejected.

3. **Adopt the artifacts layout.** State and plans are separated inside `../artifacts/<env>/`: the two `.tfstate` files live in `state/` — the non-regenerable, secret-bearing directory, created mode `0700` by `make init`, the one to back up — and saved plans in `plans/`, which is disposable. An environment whose state still sits in the old `../artifacts/<env>/terraform/` moves it once:

   ```bash
   mv ../artifacts/<env>/terraform ../artifacts/<env>/state
   ```

   Stale `tfplan-*` files in `state/` can be deleted — the next `make plan` writes fresh ones into `plans/`.

4. **Uppercase the substitution tokens** in any `values/` and `patches/` files — `${domain}` becomes `${DOMAIN}`, and so on — and move each values file to its `values/<namespace>/<release>.yaml` path ([Helm value overrides](configuration.md#helm-value-overrides)).

5. **Migrate the state keys.** The generated internal passwords are keyed by UPPER_SNAKE names now; without a state move, the next apply would regenerate every one of them — rotating live database and service credentials:

   ```bash
   # Run from the DTK tag that shipped the rename (script removed once the
   # migration window closed — check out that tag first):
   tools/migrate-uppercase-state.sh <env>            # dry run — prints every state mv, changes nothing
   tools/migrate-uppercase-state.sh <env> --apply
   ```

   The values-override ConfigMaps also changed keys and are deliberately *not* moved — they are regenerable, and their destroy/create on the next apply is harmless.

6. **Validate and plan:**

   ```bash
   make validate ENV=<env>
   make plan ENV=<env>
   ```

   The infra plan must show no changes. The config plan shows the values-override recreations from step 5 and nothing that touches a password.

## Rolling back

| What | How |
|------|-----|
| Platform workloads | Set `artifact.version` back to the previous tag, `make apply-config` |
| Infrastructure | Revert the `config.yaml` change, `make plan-apply` |
| Data | Not a rollback — see [Recover → Restore](../recover/restore.md) |

Artifact rollback is clean because the artifact is immutable and content-addressed — the previous tag is the exact previous state, and pinning means the cluster always knows which tag that was. When rolling the artifact back, check out the matching clone tag too — a `dtk_version`-pinned environment enforces this on its own.

Data is different. A bad migration that has already written to the database is not undone by reverting the artifact — that is a restore, not a rollback, and it is why point-in-time recovery exists. See [Recover](../recover/backup.md).
