# Deploy a Tooling Cluster

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Tooling Cluster

**Audiences:** adopter (deploy)

The Tooling Cluster (`role: cc`) is the management plane — OCI registry, secrets, object storage, and the observability backend that Hubs report into. Deploy it first if using one.

For the shared workflow and commands, see [Deployment](deployment.md). This page is the `cc`-specific configuration and checks.

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
| Artifact version | `v0.9.0` or `latest` | The gitops artifact Flux reconciles |
| Alert delivery | SMTP and/or Telegram | Optional, but the only way alerts leave the cluster |

## Configuration

The distinguishing settings in `config.yaml`:

```yaml
profile: "small"            # small | medium
cluster:
  name: "my-cc"
  role: "cc"                # routes Flux to the Tooling Cluster paths
  vip: "192.168.0.210"
dns:
  provider: "cloudflare"
  domain: "cc1.example.com"
app:
  lb_ipam:
    range: "192.168.0.211-192.168.0.212"   # two addresses
oci:
  repo:
    url: "oci://ghcr.io/<org>/ml-deployment-toolkit"
    version: "latest"
```

**A Tooling Cluster needs two LB addresses** — `gw-int` and `gw-ext`. It has no FSPIOP endpoint, so no third.

Full schema and secrets: [Configuration](configuration.md). The alerting-delivery secrets matter here specifically — the observability backend lives on this cluster, and without them alerts evaluate silently. See [Prerequisites](prerequisites.md#credentials-checklist).

## Deploy

Confirm the DNS zone is delegated first — see [Deployment → Pre-deploy checks](deployment.md#pre-deploy-checks):

```bash
dig +short NS cc1.example.com     # must return the DNS provider's nameservers
```

Then deploy:

```bash
make init ENV=<cc-env>
make plan ENV=<cc-env>
make apply ENV=<cc-env>
```

Expect ~15–20 minutes for Terraform, then ~10–15 for Flux to converge.

## Verify

Check up the stack — VMs, then Talos, then Kubernetes. The full commands are in [Deployment → Verify](deployment.md#verify-up-the-stack). The Tooling-Cluster-specific checks:

```bash
export KUBECONFIG=$(pwd)/artifacts/<cc-env>/kubernetes/kubeconfig

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

Admin credentials are the values the adopter set in `.env` — `HARBOR_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.

Read the admin passwords straight from the environment file:

```bash
grep -E 'MINIO_ROOT|HARBOR_ADMIN|GRAFANA_ADMIN' config/environments/<cc-env>/.env
```

Vault is auto-unsealed by its operator, which stores the unseal keys as a Secret in the `vault` namespace.

## Hand-off to the Hub

**All three service URLs must load before deploying a Hub against this cluster** — the Hub's config points at Harbor, S3, and the observability endpoints here. If any is not reachable, the Hub will fail partway through reconciliation.

These are the values a Hub's `config.yaml` consumes:

| Hub input | Value |
|-----------|-------|
| OCI cache | `harbor.int.<domain>` |
| S3 backups | `https://s3.int.<domain>` |
| Metrics endpoint | `https://thanos.int.<domain>/api/v1/receive` |
| Log endpoint | `https://loki.int.<domain>/loki/api/v1/push` |
| Trace endpoint | `https://tempo.int.<domain>/v1/traces` |

Carry them into [Deploy a Hub → Configuration](hub.md#configuration).

## After deploying

**Back up the Vault unseal keys before anything else.** They live only in cluster state and are covered by no automatic backup. Without them, a rebuilt cluster cannot open its own Vault.

```bash
kubectl -n vault get secrets
kubectl -n vault get secret <unseal-secret> -o yaml > vault-unseal-<cc-env>.yaml
```

Store that file offline. Full rationale and the disaster-recovery procedure: [Recover → Disaster recovery](../recover/disaster-recovery.md#what-the-adopter-must-keep).

Then:

- Deploy a Hub that uses this Tooling Cluster: [Deploy a Hub](hub.md)
- Confirm alerting delivery works — send a test through the contact points ([Monitoring](../operate/monitoring.md#alerting))
