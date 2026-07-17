# Backup and Restore

[docs](../index.md) / [operations](index.md) / Backup and Restore

**Audiences:** adopter (operate)

Backup schedules, restore procedures, and disaster recovery for ML Deployment Toolkit deployments. For backup design rationale and data layer architecture, see [data layer architecture](../architecture/data-layer.md).

---

## Backup overview

Backups are automatic and continuous -- deployed via GitOps with no manual setup required. Operator-managed backups (PXC, PSMDB) and CronJob-based backups (Vault) run on schedule and upload to S3-compatible storage.

| Service | Method | Schedule | Retention | Storage |
|---------|--------|----------|-----------|---------|
| MySQL (PXC) | XtraBackup to S3 | Daily (operator) | 7 days | MinIO or managed S3 |
| MongoDB (PSMDB) | pbm logical to S3 | Daily (operator) | 7 days | MinIO or managed S3 |
| Vault | Raft snapshot to S3 | Daily (CronJob) | 7 days | MinIO or managed S3 |
| Kafka | Not backed up | N/A | N/A | Transient queue |
| Redis | Not backed up | N/A | N/A | Ephemeral cache |

Kafka and Redis are intentionally excluded. Kafka is a transient message queue -- consumers replay from their committed offsets on restart. Redis is an ephemeral cache that rebuilds from the source of truth (MySQL).

## Restore commands

```bash
# Restore all services from latest backup
make restore ENV=<env>

# Restore a specific service
make restore ENV=<env> SVC=mysql
make restore ENV=<env> SVC=vault
make restore ENV=<env> SVC=mongodb

# Restore from a specific date
make restore ENV=<env> SVC=vault BACKUP=2026-02-20
```

## Restore order

When restoring all services, `make restore` follows the correct order automatically:

1. **Vault first** -- other services depend on Vault for secrets (database credentials, TLS certs)
2. **MySQL + MongoDB in parallel** -- independent of each other
3. **Verify** -- check service health after restore completes

When restoring individual services with `SVC=`, you are responsible for ordering. Always restore Vault before MySQL or MongoDB if both need restoring.

## When to restore

- After a data corruption incident
- After deploying a fresh environment that should inherit prior state (e.g., re-provisioning infrastructure for an existing deployment)
- After disaster recovery of a lost cluster

Restore is never automatic during deployment -- it is always a deliberate manual step.

## Fresh deploy vs restore

A fresh deploy without restore creates a fully functional environment. Declarative configuration (Vault `externalConfig`, `startupSecrets`, PXC operator `spec.users[]`, PSMDB operator `spec.users[]`) bootstraps everything needed for the system to run. Only runtime state requires restore:

- Enrolled DFSPs and their configuration
- Issued certificates and key material
- Transaction history and account balances
- User accounts created through MCM/Keycloak

If this is a brand-new deployment with no prior state, skip restore entirely.

## Recovery kit

Each cluster's bootstrap produces a `recovery-kit/` directory (git-ignored) containing:

- Vault root token and unseal keys
- Admin passwords (Harbor, Grafana)
- kubeconfig for cluster access
- talosconfig for node access (on-prem only)

**Store this offline immediately after bootstrap.** The recovery kit is required for disaster recovery scenarios. Without it, a total cluster loss requires full re-bootstrap and all runtime state is lost.

## Recovery scenarios

### Total loss of App Environment

Infrastructure destroyed or unrecoverable. Terraform state is preserved in the object store.

1. Retrieve Terraform state from the object store (S3/MinIO)
2. Re-provision infrastructure:
   ```bash
   make plan-apply ENV=<env>
   ```
3. Wait for operators and custom resources to become ready (~5-10 minutes)
4. Restore all services from backup:
   ```bash
   make restore ENV=<env>
   ```
5. Verify services:
   ```bash
   flux get all -n flux-system
   kubectl get pxc mojaloop-db -n mojaloop -o jsonpath='{.status.state}'
   kubectl get pods -n mojaloop
   ```

### Total loss of Tooling Cluster (if one exists)

The Tooling Cluster hosts shared services (Harbor, Vault, MinIO) used by App Environments. Its loss affects artifact distribution and centralized observability but does not immediately break running App Environments.

1. Retrieve the recovery kit from offline storage
2. Re-provision the Tooling Cluster:
   ```bash
   make plan-apply ENV=cc
   ```
3. Restore MinIO from external backup (contains OCI artifacts and service backups)
4. Unseal Vault using the root token and unseal keys from the recovery kit
5. App Environments reconnect to the Tooling Cluster automatically once Harbor and Vault are available

### Terraform state lost

If the Terraform state file is also lost (not just the cluster):

1. Re-provision from scratch with `make plan-apply ENV=<env>` (Terraform creates new state)
2. Restore from backup as above
3. Update any external references (DNS records, firewall rules) to point to new infrastructure

### Single service recovery

For targeted recovery of a single service without full cluster restore:

```bash
# MySQL only (e.g., after accidental data deletion)
make restore ENV=<env> SVC=mysql

# Vault only (e.g., after seal key rotation issue)
make restore ENV=<env> SVC=vault

# MongoDB only
make restore ENV=<env> SVC=mongodb
```

After restoring a single service, restart any pods that depend on it to pick up the restored state.
