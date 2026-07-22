# Backups

[doc](../../index.md) / [adopter](../index.md) / [recover](../index.md) / Backups

**Audiences:** adopter (recover)

What is backed up, what is not, and what you must back up yourself. For the design, see [Data layer → Backup coverage](../../architecture/data-layer.md#backup-coverage).

Read this before you need it. The gaps below are the difference between an incident and a disaster, and two of them are your responsibility, not the toolkit's.

- [What runs automatically](#what-runs-automatically)
- [What is not backed up](#what-is-not-backed-up)
- [What you must back up yourself](#what-you-must-back-up-yourself)
- [Verifying backups](#verifying-backups)

## What runs automatically

Deployed and running with no action from you. Everything lands in S3-compatible storage — MinIO on the Tooling Cluster, or a cloud object store.

| Store | Mechanism | Schedule | Retained | Point-in-time |
|-------|-----------|----------|----------|:---:|
| MySQL | Percona xtrabackup → S3 | Daily 01:00 | 7 backups | **Yes** — binlogs streamed |
| MongoDB | Percona Backup → S3 | Daily 01:00 | 7 backups | **Yes** — oplog streamed |
| Vault | Raft snapshot → S3 | **Every 15 min** | **Last 7 snapshots** | No |

**MySQL and MongoDB each run two mechanisms together.** The daily full backup is a complete copy; the continuous stream (binlog for MySQL, oplog for MongoDB) fills the gaps between full backups. Together they give point-in-time recovery — you can restore to the moment before a bad write, not just to last night at 01:00. See [Restore](restore.md).

**Read the Vault row carefully.** It keeps the last seven 15-minute snapshots — about **one hour and forty-five minutes** of history, not seven days. Vault holds the scheme PKI. A corruption or compromise discovered more than two hours later has no clean snapshot to fall back to. If that window is too short for your risk posture, it is a configuration change worth making deliberately.

## What is not backed up

**Kafka — none, by design.** Kafka is a transport, not a system of record. Committed state lands in MySQL and MongoDB; a total Kafka loss costs in-flight events, not settled positions. Whether that is acceptable is a scheme-level decision — make it explicitly rather than assuming.

**Redis — none, and none needed.** It is a cache. Losing it costs a cold start.

## What you must back up yourself

Two things sit outside every automatic backup, and both make a cluster unrecoverable if lost. Nothing in the toolkit backs them up for you.

### Vault unseal keys

The operator auto-unseals Vault by storing the unseal keys and root token as a Secret in the `vault` namespace. That works perfectly while the cluster lives — and is worthless if the cluster dies, because the Secret dies with etcd. The Vault raft snapshots are encrypted; without the unseal keys they cannot be opened.

Back the Secret up out of band, on **every** cluster — the Tooling Cluster and each Hub:

```bash
kubectl -n vault get secrets
kubectl -n vault get secret <unseal-secret> -o yaml > vault-unseal-<cluster>.yaml
```

The operator names the Secret after the Vault resource — list the namespace to find the exact name on your cluster. Store the file offline, and treat it with the same care as the root token: anyone who has it can unseal your Vault and read the scheme's private keys.

### Terraform state

State lives locally under `artifacts/<env>/terraform/`. There is no remote backend, no locking, no versioning — and `make clean` deletes it. Losing it means Terraform no longer knows about your infrastructure: the cluster keeps running, but you can no longer plan, apply, or cleanly destroy it.

Back up `artifacts/<env>/` on every environment you care about. A copy after each successful `make apply` is enough.

Both gaps are recorded in `discrepancies.md` — the toolkit does not yet discharge these for you, so treat them as standing operational tasks.

## Verifying backups

A backup you have never restored is a hypothesis. At minimum, confirm they are being produced:

```bash
# MySQL backups the operator knows about
kubectl -n data get pxc-backup

# MongoDB backups
kubectl -n data get psmdb-backup

# Vault snapshots in object storage — check the bucket
# path: <bucket>/<cluster>/vault/vault-raft-<timestamp>.snap
```

Objects should be appearing on the daily schedule for the databases and every 15 minutes for Vault. If the bucket is empty, the backups are not running — investigate that now, not during an incident. The most common cause is the S3 credentials or the [callback-egress policy blocking egress on an empty Hub](../operate/known-issues.md#dfsp-callback-egress-policy-hijacks-all-port-80443-traffic-before-any-participant-is-enrolled).

Proving a backup is *restorable* means actually restoring it — see [Restore](restore.md). Do it once, in a lab, before you have to do it for real.
