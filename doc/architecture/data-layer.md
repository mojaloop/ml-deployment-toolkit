# Data Layer

[doc](../index.md) / [architecture](index.md) / Data layer

**Audiences:** architect, platform developer, adopter (operate), adopter (recover)

The four data stores, how they are backed up, and what is recoverable.

- [The four stores](#the-four-stores)
- [Where they live](#where-they-live)
- [MySQL](#mysql)
- [Kafka](#kafka)
- [MongoDB](#mongodb)
- [Redis](#redis)
- [Backup coverage](#backup-coverage)
- [What is not recoverable](#what-is-not-recoverable)

## The four stores

| Store | Implementation | Holds |
|-------|---------------|-------|
| MySQL | Percona XtraDB Cluster | Ledger, participants, quotes, oracle, auth, MCM |
| Kafka | Strimzi | Event streaming between Mojaloop services |
| MongoDB | Percona Server for MongoDB | Bulk transfer state |
| Redis | Redis operator | Testing Toolkit cache |

All four run only on a Hub. A Tooling Cluster has none of them.

## Where they live

**Every data store is in the `data` namespace — not `mojaloop`.** This is the single most common source of "my cluster looks empty" confusion. Commands aimed at `mojaloop` return nothing and look like a healthy result.

Services reach them by fully-qualified in-cluster DNS:

| Store | Address |
|-------|---------|
| MySQL | `mojaloop-db-haproxy.data.svc.cluster.local:3306` |
| Kafka | `mojaloop-kafka-kafka-bootstrap.data.svc.cluster.local:9092` |
| MongoDB | `bulk-mongodb-rs0.data.svc.cluster.local:27017` |
| Redis | `ttk-redis.data.svc.cluster.local:6379` |

Those are the defaults for a store running **in-cluster**. Both host and port are substitution variables, so an external endpoint on a non-standard port works the same way. The addresses are resolved by Terraform at plan time and substituted into manifests by Flux, which is why the same artifact works across environments without being rebuilt.

Each store is bound independently, in `data.<store>.mode`:

| Mode | Effect on this page |
|------|---------------------|
| `in-cluster-managed` (default) | Everything below applies — operator, custom resource, and the toolkit's backup path |
| `external-unmanaged` | The adopter supplies the endpoint and credentials. No operator, no custom resource, no `hub-data-<store>` Kustomization, and **no toolkit backup** — provisioning, tuning, and recovery are the adopter's |
| `external-managed` | Reserved in the schema, rejected at plan time. Not available |

Mixing modes is supported — external MySQL alongside in-cluster Kafka is a valid Hub. See [Configuration → Data modes](../adopter/deploy/configuration.md#data-modes).

The database **operators** live elsewhere again, in `hub-system`. Four namespaces are therefore involved in a data-layer problem: `hub-system` for the operator, `data` for the cluster, and the clients in `mojaloop` and `finance-portal` — the Finance Portal's reporting APIs read `central_ledger` and MongoDB directly.

## MySQL

Percona XtraDB Cluster, three nodes, fronted by three HAProxy replicas. Applications connect to HAProxy, never to a node directly.

Seven databases, each with its own user and credentials:

| Database | Owner |
|----------|-------|
| `central_ledger` | Mojaloop core |
| `account_lookup` | Account lookup service |
| `oracle_msisdn` | MSISDN oracle |
| `kratos` | Ory Kratos |
| `keto` | Ory Keto |
| `hydra` | Ory Hydra |
| `mcm` | Connection Manager |

There is no `keycloak` database. Any reference to one is stale ([ADR-010](decisions/010-dual-realm-keycloak.md), superseded).

A single cluster hosts all seven rather than one cluster per service ([ADR-009](decisions/009-single-mysql-cluster.md)).

**Users are created asynchronously by the operator**, taking roughly 7–10 minutes after the cluster is created. The reconciliation chain gates `hub-auth` on the cluster reporting `ready` — the state the operator sets only once users exist ([ADR-019](decisions/019-health-gated-reconciliation.md)) — see [System overview](system-overview.md#reconciliation-order).

## Kafka

Strimzi-managed, three brokers in KRaft mode with `min.insync.replicas: 2`. Mojaloop services communicate through it for transfer and settlement events.

It also matters to tracing, in two ways: trace context crosses it as a `traceparent` message header, which is what joins producer and consumer spans into one end-to-end trace, and the legacy Event-SDK path still emits spans to `topic-event-trace`, which a (now superseded) bridge converts to OTLP and forwards to Tempo. See [Observability](observability.md#tracing).

## MongoDB

Percona Server for MongoDB, replica set `rs0`, holding bulk transfer state. Three application users: `mlos`, `ttk`, and `reporting`, all read-write.

## Redis

A cache for the Testing Toolkit. It holds no durable state — losing it costs nothing but a cold cache.

## Backup coverage

MySQL and MongoDB each run **two mechanisms together**, and the distinction matters when the adopter weighs how much data an incident can cost.

**Scheduled full backups** — a complete copy taken on a timer. Restores land exactly on a backup boundary.

**Continuous streaming (PITR)** — transaction logs shipped to object storage between full backups. This is what allows a restore to an arbitrary moment rather than to last night at 01:00, and it is enabled on both stores.

| Store | Full backup | Streaming (PITR) | Retention |
|-------|-------------|:---:|-----------|
| MySQL | xtrabackup → S3, daily 01:00 | **Enabled** — binlogs streamed continuously | 7 backups |
| MongoDB | Percona Backup → S3, daily 01:00 | **Enabled** — oplog streamed continuously | 7 backups |
| Vault | Raft snapshot → S3, **every 15 min** | Not applicable | **Last 7 snapshots** |
| Kafka | **None** | — | — |
| Redis | **None** | — | — |

Practically: PITR recovers the ledger to the second before a bad write, not merely to the previous night. Without it, worst-case exposure would be a full day of transfers.

Both mechanisms write to whatever the `object_storage` capability is bound to — a Tooling Cluster's MinIO or any S3-compatible endpoint, stated explicitly in `object_storage.endpoint` ([ADR-017](decisions/017-explicit-capability-endpoints.md)). A store bound to `external-unmanaged` is outside this table entirely: the toolkit schedules nothing for it. **A full backup alone is not restorable to a point in time, and streamed logs alone are not restorable at all** — recovery needs both, so both must survive.

**Read the Vault row carefully, twice.** First, snapshots run every fifteen minutes and only the last seven are kept, so the retained history spans **90 minutes** — not seven days. Vault holds the scheme PKI; a compromise or corruption discovered two hours later has no clean snapshot from before it. Second, the snapshot CronJob ships **on the Hub only** — a Tooling Cluster's Vault has no scheduled snapshot, and protecting it is the adopter's own arrangement.

**Kafka has no backup by design.** It is a transport, not a system of record; committed state lands in MySQL and MongoDB. A total Kafka loss costs in-flight events, not settled positions. Whether that is acceptable is a scheme-level decision worth making explicitly rather than inheriting.

**Redis has no backup and needs none** — it is a cache.

Restore procedures: [Adopter → Recover](../adopter/index.md).

## What is not recoverable

Three things sit outside the backup story entirely, and each has bitten someone:

**Terraform state.** Two files, stored locally under `../artifacts/<env>/terraform/` — a sibling of the clone — `infra.tfstate` and `config.tfstate`, with no remote backend, no locking, and no versioning. No make target deletes them — `make clean ENV=<env>` preserves `../artifacts/<env>/terraform/` — but nothing else protects them either. Losing the infra state means losing Terraform's knowledge of the infrastructure — the cluster keeps running, but Terraform can no longer plan or apply against it. Losing the config state means losing the generated internal service passwords unless the cluster is still up to read them from. Backing up `../artifacts/` falls to the adopter.

**Vault unseal keys.** Less alarming than it sounds — the operator handles unsealing automatically. Vault is configured with `unsealConfig.kubernetes`, so the operator generates the unseal keys and root token at initialization and **stores them as a Secret in the `vault` namespace**. A pod restart unseals without human involvement.

What is *not* handled is losing the cluster. That Secret lives only in etcd, so it is covered by neither the Vault raft snapshots nor the database backups. Rebuild the cluster without it and the snapshots are unopenable — what remains is encrypted data and no key.

Back it up out-of-band, on both the Hub and the Tooling Cluster:

```bash
kubectl -n vault get secret vault-unseal-keys -o yaml > vault-unseal-<cluster>.yaml
```

The operator derives the Secret name from the Vault resource; with the shipped resource named `vault` it is `vault-unseal-keys` on both cluster roles.

Treat that file with the same care as the root token — anyone holding it can unseal Vault and read the scheme's private keys.

**In-flight Kafka events.** As above.

The first two are operational obligations that the tooling does not currently discharge on the adopter's behalf. Treat them as manual steps with the same seriousness as the automated backups.
