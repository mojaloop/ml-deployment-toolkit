# Restore

[doc](../../index.md) / [adopter](../index.md) / [recover](../index.md) / Restore

**Audiences:** adopter (recover)

Restoring MySQL, MongoDB, and Vault from backup. For rebuilding a whole cluster, see [Disaster recovery](disaster-recovery.md).

> **There is no `make restore`.** Restore is driven by the database operators' own custom resources and by Vault's snapshot command. This page describes those mechanisms. The exact field names on a restore resource depend on the operator version you are running — **check the schema against your deployed operator's CRD before applying**, and rehearse in a lab before you rely on it in production. The steps below are the shape, not a byte-for-byte script.

- [Before you restore](#before-you-restore)
- [MySQL](#mysql)
- [MongoDB](#mongodb)
- [Vault](#vault)
- [After restoring](#after-restoring)

## Before you restore

Restoring overwrites live data. Three things to establish first:

1. **What are you recovering from** — a bad migration, a corrupted table, a lost cluster? A localized corruption is a point-in-time restore; a lost cluster is [disaster recovery](disaster-recovery.md).
2. **What is the target time** — point-in-time restore needs a timestamp before the damage. Find it in the logs or the audit trail, not by guessing.
3. **Can you afford the overwrite** — a restore replaces current state. If current state has *some* good data written after the target time, capture it first.

Everything data-layer is in the `data` namespace.

## MySQL

Percona XtraDB Cluster restores through a `PerconaXtraDBClusterRestore` resource that the operator reconciles. It references the cluster and the backup storage — the storage name configured on the cluster is `s3-backup`.

**Restore from a specific backup.** List what the operator has:

```bash
kubectl -n data get pxc-backup
```

Then create a restore resource naming the cluster (`mojaloop-db`) and the chosen backup. Apply it in `data`, and the operator pauses the cluster, restores, and brings it back.

**Point-in-time restore** uses the streamed binlogs to roll forward to a target time rather than restoring to a backup boundary. The restore resource takes a PITR section with the target — confirm its exact shape against your operator version.

Watch the restore:

```bash
kubectl -n data get pxc-restore -w
kubectl -n data get pxc mojaloop-db -o jsonpath='{.status.state}'
```

The cluster returns to `ready` when the restore completes. Expect the application layer to reconnect on its own once MySQL is back — if a service does not, restart its pod.

## MongoDB

Percona Server for MongoDB restores through a `PerconaServerMongoDBRestore` resource, the same pattern. Storage name is `s3-backup`; the cluster is `bulk-mongodb`.

```bash
kubectl -n data get psmdb-backup          # available backups
# create a PerconaServerMongoDBRestore referencing bulk-mongodb + the backup
kubectl -n data get psmdb-restore -w      # watch it
```

Point-in-time restore uses the streamed oplog to a target time. As with MySQL, confirm the field layout against your operator version before applying.

## Vault

Vault is different — it is not operator-restored. You restore a raft snapshot with Vault's own command, and it is more disruptive, because unsealing and the token that authorizes the restore are involved.

The snapshots are in object storage at `<bucket>/<cluster>/vault/vault-raft-<timestamp>.snap`, taken every 15 minutes.

The outline:

1. **Retrieve the snapshot** from object storage — the one from before the damage.
2. **Authenticate to Vault** with a token that can perform the restore. On a running Vault this is the root token; if Vault is lost, you need the root token from your [out-of-band backup](backup.md#vault-unseal-keys).
3. **Restore:**
   ```bash
   vault operator raft snapshot restore vault-raft-<timestamp>.snap
   ```
4. **Re-verify the PKI** — the scheme CA, the issuing roles, and participant certificate material should all be present after restore. Confirm the CA responds before assuming participant connections will work.

Restoring Vault rolls back **everything** it holds — the PKI, service credentials, participant certificate records — to the snapshot moment. Anything issued in the gap between the snapshot and the restore is gone. For the PKI specifically, that can mean a participant enrolled in that window is no longer known to the Hub and must re-enrol.

Because Vault's window is short (about 1h45m of snapshots) and the blast radius is wide, a Vault restore is close to a rebuild. If the situation is that bad, read [Disaster recovery](disaster-recovery.md) first.

## After restoring

- **Confirm the data is what you expected** — a restore to the wrong point is worse than none, because it looks successful. Spot-check known records against the target time.
- **Reconcile the layers above.** A database rolled back behind the application can leave services holding stale references. Restart the affected Mojaloop or auth pods if they do not recover on their own.
- **Check participant connectivity** if Vault or the PKI was involved — the trust bundle and certificates must still line up. See [Participant mTLS](../../architecture/participant-mtls.md).
- **Record what happened.** A restore is a real incident; the timeline and the target-time decision are worth writing down while they are fresh.
