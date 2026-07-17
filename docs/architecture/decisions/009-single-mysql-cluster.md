# 009 — Single PXC cluster for all MySQL databases

[docs](../../index.md) / [architecture](../index.md) / [decisions](./) / 009 — Single PXC cluster for all MySQL databases

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform engineer, DBA

## Context

Mojaloop requires multiple MySQL databases: `central_ledger`, `account_lookup`, `oracle_msisdn` (core switch), `keycloak`, `kratos`, `keto` (auth stack), and `mcm` (connection manager). Each database has different access patterns but similar availability and backup requirements. The Percona XtraDB Cluster (PXC) operator manages Galera-based MySQL clusters on Kubernetes.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| One PXC cluster per database | Fault isolation, independent scaling, independent backup schedules | 7 separate clusters (7x HAProxy, 7x replication streams, 21+ pods minimum), high resource overhead, complex operations |
| Single shared PXC cluster | Resource efficient (1 HAProxy, 1 replication stream), unified backup, simpler operations | All databases share failure domain, no independent scaling per database |

## Decision

Single PXC cluster named `mojaloop-db` hosting all databases. Users and databases are provisioned declaratively via the PXC operator's `spec.users[]` feature (available since PXC operator v1.16+), eliminating the need for init jobs or manual SQL provisioning.

A unified MySQL endpoint `${mysql_host}` replaces the prior per-database host variables (`mysql_central_ledger_host`, `mysql_account_lookup_host`, `auth_db_host`), simplifying Flux substitution configuration.

## Consequences

- **Resource efficient.** One HAProxy instance, one Galera replication stream, one set of PXC pods. Compared to 7 separate clusters, this saves approximately 14 pods and ~4Gi RAM.
- **Unified backup schedule.** All databases are backed up together via the PXC operator's `spec.backup` configuration. Single restore point covers all databases.
- **Shared failure domain.** A PXC cluster failure affects all databases simultaneously. Acceptable because Mojaloop services are interdependent -- a `central_ledger` outage already halts the switch regardless of other database availability.
- **Declarative user provisioning.** `spec.users[]` creates databases, users, and grants declaratively. No init jobs, no imperative SQL scripts, no race conditions during bootstrap.
- **Single `${mysql_host}`.** All services connect to the same HAProxy endpoint, differing only by database name and credentials. Simplifies configuration and troubleshooting.
