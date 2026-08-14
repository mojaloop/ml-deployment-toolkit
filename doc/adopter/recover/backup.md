# Backups

[doc](../../index.md) / [adopter](../index.md) / [recover](../index.md) / Backups

**Audiences:** adopter (recover)

What is backed up, what is not, and what the adopter must back up. For the design, see [Data layer → Backup coverage](../../architecture/data-layer.md#backup-coverage).

Read this before it is needed. The gaps below are the difference between an incident and a disaster, and two of them are the adopter's responsibility, not the toolkit's.

- [What runs automatically](#what-runs-automatically)
- [What the adopter must back up](#what-the-adopter-must-back-up)
- [Verifying backups](#verifying-backups)

## What runs automatically

On a Hub with `object_storage.enabled: true`, the toolkit backs up MySQL, MongoDB, and Vault to the configured S3 endpoint — daily fulls with continuous point-in-time streaming for the databases, a 15-minute Raft snapshot cycle for Vault. The full coverage table, schedules, and retention are owned by [Data layer → Backup coverage](../../architecture/data-layer.md#backup-coverage); restoring is [Restore](restore.md).

Four caveats decide whether "automatic" is actually true on a given deployment:

- **`object_storage.enabled: false` disables all of it** — no database backups, no PITR, no Vault snapshots ([Configuration → Supporting services](../deploy/configuration.md#supporting-services)).
- **A store bound `external-unmanaged` is outside the toolkit's backup path entirely** — its backups are the adopter's own arrangement.
- **The Vault snapshot cycle runs on Hubs only.** A Tooling Cluster's Vault has no scheduled snapshot.
- **The Vault window is 90 minutes**, not seven days — seven snapshots at 15-minute spacing. Vault holds the scheme PKI; a corruption or compromise discovered later has no clean snapshot to fall back to. If that window is too short for the scheme's risk posture, change it knowingly.

Kafka and Redis have no backup — Kafka is a transport whose committed state lands in the databases, Redis a cache. Whether losing in-flight Kafka events is acceptable is a scheme-level decision — make it explicitly rather than assuming.

## What the adopter must back up

Three things sit outside every automatic backup, and each makes a cluster unrecoverable or unreproducible if lost. Nothing in the toolkit backs them up.

### Vault unseal keys

The operator auto-unseals Vault by storing the unseal keys and root token as a Secret in the `vault` namespace. That works perfectly while the cluster lives — and is worthless if the cluster dies, because the Secret dies with etcd. The Vault raft snapshots are encrypted; without the unseal keys they cannot be opened.

Back the Secret up out of band, on **every** cluster — the Tooling Cluster and each Hub:

```bash
kubectl -n vault get secret vault-unseal-keys -o yaml > vault-unseal-<cluster>.yaml
```

The operator derives the name from the Vault resource; with the shipped resource named `vault`, the Secret is `vault-unseal-keys` on both roles. Store the file offline, and treat it with the same care as the root token: anyone who has it can unseal the Vault and read the scheme's private keys.

### Terraform state

State lives locally under `../artifacts/<env>/terraform/`, in two files: `infra.tfstate` for the cluster and `config.tfstate` for everything Flux consumes. The `../artifacts/` tree is a sibling of the clone and the environment repository, tracked by neither — there is no remote backend, no locking, and no versioning; nothing but a copy protects it. (`make clean ENV=<env>` preserves `../artifacts/<env>/terraform/` — it removes only the regenerable artifacts around it.) Losing the infra state means Terraform no longer knows about the infrastructure: the cluster keeps running, but the adopter can no longer plan, apply, or cleanly destroy it. Losing the config state loses Terraform's copy of the **generated internal service passwords**. While the cluster still runs they can be read back from the `cluster-secrets` Secret in `flux-system`; once both are gone they are gone. `make secrets ENV=<env>` reads the state file, not the cluster, so it stops working the moment that file does.

Back up `../artifacts/<env>/` — both state files — on every environment that matters. A copy after each successful `make apply` or `make apply-config` is enough.

### The environment repository and `.env`

The environment directory `../environments/<env>/` is its own git repository, and its backup story is git's: give it a private remote and push. That covers `config.yaml`, `placement.yaml`, `proxmox/proxmox.yaml`, `values/`, and `patches/` — everything needed to reproduce the cluster's identity.

**`.env` is the exception.** The shipped `.gitignore` keeps it out of the repository, and it must never be committed anywhere — so the remote does not protect it. Keep a secure copy out of band, with the same care as the Vault unseal keys: it holds every external credential the deployment uses.

The toolkit does not discharge any of these on the adopter's behalf — treat them as standing operational tasks.

## Verifying backups

A never-restored backup is a hypothesis. At minimum, confirm they are being produced:

```bash
# MySQL backups the operator knows about
kubectl -n data get pxc-backup

# MongoDB backups
kubectl -n data get psmdb-backup

# Vault snapshots in object storage — check the bucket
# path: <bucket>/<cluster>/vault/vault-raft-<timestamp>.snap
```

Objects should be appearing on the daily schedule for the databases and every 15 minutes for Vault. If the bucket is empty, the backups are not running — investigate that now, not during an incident. The usual causes are wrong `BACKUP_S3_*` credentials, an unreachable `object_storage.endpoint`, or the section quietly left at `enabled: false`.

Proving a backup is *restorable* means actually restoring it — see [Restore](restore.md). Do it once, in a lab, before doing it for real.
