# Deploy a Tooling Cluster

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Tooling Cluster

**Audiences:** adopter (deploy)

The Tooling Cluster (`role: tooling`) hosts the supporting services a Hub points at — OCI registry and pull-through cache, object storage for backups, and the observability backend Hubs report into. It is a reference implementation: each of those endpoints may equally point anywhere else ([ADR-017](../../architecture/decisions/017-explicit-capability-endpoints.md)). Deploy it first if using one.

For the shared workflow and commands, see [Deployment](deployment.md). This page is the `tooling`-specific configuration and checks.

- [When to deploy one](#when-to-deploy-one)
- [Inputs](#inputs)
- [Configuration](#configuration)
- [Deploy](#deploy)
- [Verify](#verify)
- [Accessing services](#accessing-services)
- [Hand-off to the Hub](#hand-off-to-the-hub)
- [After deploying](#after-deploying)

## When to deploy one

A Tooling Cluster is optional. A single Hub can pull artifacts from a public registry and run standalone.

It earns its place when the adopter runs more than one environment, or needs to operate air-gapped. It provides:

- **Harbor** — a pull-through cache, so Hubs pull images once through the Tooling Cluster rather than repeatedly from the internet
- **MinIO** — shared object storage for backups, metrics, and logs
- **Observability backend** — Thanos, Loki, Tempo, and Grafana, aggregating every Hub
- **Vault** — its own secrets and PKI, independent of any Hub's

## Inputs

Decide these before starting — they are what `config.yaml` and the pre-checks reference.

| Input | Example | Notes |
|-------|---------|-------|
| Proxmox node(s) | `worker4` | A single node is fine for a Tooling Cluster |
| Kubernetes API VIP | `192.168.0.210` | Floating IP, same L2 as the nodes |
| LB-IPAM range | `192.168.0.211-212` | **Two** addresses |
| DNS zone | `cc1.example.com` | Delegated before deploying |
| Artifact version | `v0.19.0` | The gitops artifact Flux reconciles — always a pinned tag |
| Alert delivery | SMTP and/or Telegram | Optional, but the only way alerts leave the cluster |

## Configuration

The distinguishing settings in `config.yaml`:

```yaml
version: 1
template: "small"           # dev | small | medium
cluster:
  name: "my-cc"             # optional — defaults to the environment directory name
  role: "tooling"                # routes Flux to the Tooling Cluster paths
  vip: "192.168.0.210"
  lb_ipam:
    pools:                    # two addresses — one per gateway
      gw-int:
        lan: "192.168.0.211"
      gw-ext:
        lan: "192.168.0.212"
dns:
  provider: "cloudflare"
  domain: "cc1.example.com"
cert:
  email: "ops@example.com"  # ACME account contact
  server: "https://acme-v02.api.letsencrypt.org/directory"  # selects the CA
artifact:
  url: "oci://ghcr.io/<org>/ml-deployment-toolkit"
  version: "v0.19.0"          # a pinned vX.Y.Z tag — "latest" is rejected
registry:
  enabled: false            # Harbor lives here; nothing to proxy through
object_storage:
  enabled: false            # MinIO lives here; this cluster is the backup target
observability:
  enabled: false            # the telemetry backend lives here too
```

**A Tooling Cluster needs two LB addresses** — `gw-int` and `gw-ext`. It has no FSPIOP endpoint, so no third.

A Tooling Cluster has no `data` and no `app` section — it is the cluster others point at. It still declares `registry`, `object_storage` and `observability` with `enabled: false`: all three are required, and off is stated rather than left to an omitted section. Start by copying `examples/environments/tooling/` out of the clone ([Configuration → Environment layout](configuration.md#environment-layout)).

Full schema and secrets: [Configuration](configuration.md). Alerting matters here specifically — the observability backend lives on this cluster, so the `alerting:` section and its `.env` credentials are what decide whether alerts leave it. See [Prerequisites](prerequisites.md#credentials-checklist).

## Deploy

Confirm the DNS zone is delegated first — see [Deployment → Pre-deploy checks](deployment.md#pre-deploy-checks):

```bash
dig +short NS cc1.example.com     # must return the DNS provider's nameservers
```

Then validate and deploy:

```bash
make validate ENV=<tooling-env>
make plan-apply ENV=<tooling-env>
```

Expect about five minutes for Terraform, then ~10–15 for Flux to converge.

## Verify

Check up the stack — VMs, then Talos, then Kubernetes. The full commands are in [Deployment → Verify](deployment.md#verify-up-the-stack). The Tooling-Cluster-specific checks:

```bash
export KUBECONFIG=$(pwd)/../artifacts/<tooling-env>/kubernetes/kubeconfig

# Two gateways, each with a LoadBalancer address
kubectl get gateways -n platform-system

# Wildcard certificates Ready
kubectl get certificates -n platform-system

# Core namespaces populated
kubectl get pods -n vault
kubectl get pods -n harbor
kubectl get pods -n minio
kubectl get pods -n observability
```

Expect **two** gateways with addresses, `gw-int` and `gw-ext`. If a certificate is not Ready, it is almost always DNS — the ACME challenge needs the zone reachable, which is why the delegation pre-check matters. See [Troubleshooting](../operate/troubleshooting.md).

## Accessing services

Services are published at `https://<service>.int.<domain>`, where `<domain>` is `dns.domain`.

| Service | URL |
|---------|-----|
| Vault | `https://vault.int.<domain>` |
| Harbor | `https://harbor.int.<domain>` |
| MinIO console | `https://minio.int.<domain>` |
| Grafana | `https://grafana.int.<domain>` |

Admin credentials are **generated**, not authored. Read them back from the config stack:

```bash
make secrets ENV=<tooling-env>
```

That prints `HARBOR_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, and `MINIO_ROOT_PASSWORD`, plus one entry per Hub credential declared here (`HARBOR_ROBOT_<NAME>_SECRET`, `MINIO_BUCKET_<NAME>_SECRET_KEY`). The MinIO user name is `minioadmin` unless `MINIO_ROOT_USER` was set in `.env`; Harbor and Grafana log in as `admin`.

Vault is auto-unsealed by its operator, which stores the unseal keys as the `vault-unseal-keys` Secret in the `vault` namespace.

## Hand-off to the Hub

**All three service URLs must load before deploying a Hub against this cluster** — the Hub pulls images through Harbor, backs up to S3, and pushes telemetry to the observability endpoints here. If any is not reachable, the Hub will fail partway through reconciliation.

A Hub reaches this cluster through three endpoints it names in its own config — the Harbor registry, the S3 backup target, and the telemetry push URLs. They follow this cluster's `dns.domain`:

| Service | Endpoint |
|---------|----------|
| Registry | `harbor.int.<this cluster's domain>` |
| Backup S3 | `https://s3.int.<domain>` |
| Metrics | `https://thanos.int.<domain>/api/v1/receive` |
| Logs | `https://loki.int.<domain>/loki/api/v1/push` |
| Traces | `https://tempo.int.<domain>/v1/traces` |

Write them into the Hub's `registry`, `object_storage`, and `observability` sections — see [Hub → Supporting services](hub.md#supporting-services). Each endpoint is stated outright; there is no shorthand that derives them from this cluster's domain ([ADR-017](../../architecture/decisions/017-explicit-capability-endpoints.md)).

Give each Hub its own registry account and backup bucket by declaring them here, named after the Hub's `cluster.name`:

```yaml
registry:
  robots:
    - name: "my-switch"
object_storage:
  buckets:
    - name: "my-switch-backups"
```

Each declared robot is created in Harbor as a pull-only account (`robot-<name>`) with a generated secret, so a Hub never holds the Harbor admin credential. Each declared bucket is created in MinIO with a generated user scoped to that one bucket, so a Hub's credentials cannot touch another Hub's backups — see [Configuration → A Tooling Cluster, annotated](configuration.md#a-tooling-cluster-annotated). Both are additive and creation-only: removing an entry stops managing it but deletes nothing.

Two credentials do have to travel, because they are generated here and supplied there:

```bash
make secrets ENV=<tooling-env>
```

| Hub `.env` variable | Value from `make secrets` |
|---------------------|---------------------------|
| `OCI_PROXY_USERNAME` / `OCI_PROXY_PASSWORD` | `robot-<name>` / `HARBOR_ROBOT_<NAME>_SECRET` |
| `BACKUP_S3_ACCESS_KEY` / `BACKUP_S3_SECRET_KEY` | `<bucket name>` / `MINIO_BUCKET_<NAME>_SECRET_KEY` |

With no declared robots or buckets, the fallbacks are the shared credentials — `admin` / `HARBOR_ADMIN_PASSWORD` for the registry, and the `backups` system bucket with `minioadmin` / `MINIO_ROOT_PASSWORD` for S3. Workable for a single Hub, but admin credentials in a Hub's `.env` are exactly what the scoped accounts exist to avoid.

Carry those into [Deploy a Hub → Configuration](hub.md#configuration).

## After deploying

**Back up the Vault unseal keys before anything else.** They live only in cluster state and are covered by no automatic backup — and a Tooling Cluster's Vault has no scheduled snapshot at all ([Data layer → Backup coverage](../../architecture/data-layer.md#backup-coverage)). Without the keys, a rebuilt cluster cannot open its own Vault.

```bash
kubectl -n vault get secret vault-unseal-keys -o yaml > vault-unseal-<tooling-env>.yaml
```

Store that file offline. Full rationale and the disaster-recovery procedure: [Recover → Disaster recovery](../recover/disaster-recovery.md#what-the-adopter-must-keep).

Then:

- Deploy a Hub that uses this Tooling Cluster: [Deploy a Hub](hub.md)
- Confirm alerting delivery works — send a test through the contact points ([Monitoring](../operate/monitoring.md#alerting))
