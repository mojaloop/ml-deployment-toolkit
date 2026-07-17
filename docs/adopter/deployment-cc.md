# Deploy a Tooling Cluster (CC)

[docs](../index.md) / [adopter](index.md) / Deploy a Tooling Cluster

**Audiences:** adopter (deploy)

The Tooling Cluster hosts the shared management-plane services: Harbor (OCI registry and pull-through cache), Vault (secrets and PKI), MinIO (or managed S3) for object storage, FluxCD, and the observability stack. Switch clusters pull artifacts and credentials from it. A Tooling Cluster is optional for single-environment setups but recommended for multi-environment or air-gapped operation.

This page covers what's specific to a CC deployment. For the shared `make plan-apply` workflow, commands reference, and destroy, see [Deployment](deployment.md).

---

## Before you start

- Provider account and credentials — see [provider setup](provider-setup/index.md)
- DNS zone delegated to your DNS provider — see [DNS provider setup](provider-setup/index.md)
- Environment scaffolded under `config/environments/<env>/` — see [Configuration](configuration.md)

---

## Configure

The Tooling Cluster uses a CC-specific sizing profile and skips the `app`/`backup`/`observability` fields that only apply to Switches.

Minimal `config.yaml` shape:

```yaml
infra:
  provider: "proxmox"        # or aws, digitalocean
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"
    network_bridge: "vmbr0"
    storage: { disks: "local-lvm", images: "local", snippets: "local" }

profile: "small"              # CC sizing profile (config/providers/<provider>/profiles/cc/)

cluster:
  name: "ml-cc"
  role: "cc"                  # routes Flux to deploy gitops/cc/, cc-config/, cc-routes/
  vip: "192.168.88.10"        # on-prem only — floating IP for the K8s API

dns:
  provider: "digitalocean"
  domain: "cc1.example.com"

app:
  lb_ipam:
    range: "192.168.88.11-192.168.88.12"   # on-prem LoadBalancer IP pool
  alert_email: "ops@example.com"

oci:
  repo:
    active: true
    url: "oci://ghcr.io/<org>/ml-deployment-toolkit"
    version: "latest"
  proxy:
    active: false             # CC hosts Harbor — it doesn't pull through itself
```

Required `.env` secrets in `config/environments/<env>/.env`:

- Provider credentials (`PROXMOX_VE_*`, `AWS_*`, or `DIGITALOCEAN_TOKEN`)
- DNS credentials (`DIGITALOCEAN_TOKEN`, `CLOUDFLARE_API_TOKEN`, or `AWS_*`)
- OCI repo credentials (`OCI_REPO_USERNAME`, `OCI_REPO_PASSWORD`) if the registry is private
- `HARBOR_ADMIN_PASSWORD`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`

Full schema and secrets reference: [Configuration](configuration.md).

---

## Deploy

```bash
make plan-apply ENV=<env>
```

See [Deployment](deployment.md#plan-and-apply) for what happens during apply.

---

## Verify

Run the shared checks in [Deployment > Verify](deployment.md#verify) first, then the CC-specific checks below.

```bash
export KUBECONFIG=$(pwd)/artifacts/<env>/kubernetes/kubeconfig

# Gateways should have LoadBalancer addresses (3 IPs: gw-int, gw-ext, gw-extapi)
kubectl get gateways -n platform-system

# Wildcard TLS certificates should be Ready
kubectl get certificates -n platform-system

# Tooling Cluster namespaces should exist
kubectl get ns vault harbor minio

# Service pods should be running
kubectl get pods -n vault
kubectl get pods -n harbor
kubectl get pods -n minio

# HTTPRoutes should be Accepted
kubectl get httproutes -A
```

Vault unseal keys, Harbor admin password, kubeconfig, and talosconfig are written to a `recovery-kit/` directory at the repo root (git-ignored). **Store this offline before destroying the cluster.** See [Security](../architecture/security.md) for details.

---

## Accessing Tooling Cluster services

Services are exposed via Gateway API HTTPRoutes at `https://<service>.int.<domain>`, where `<domain>` is `dns.domain` from `config.yaml`.

| Service | URL pattern | Purpose |
|---------|-------------|---------|
| Vault | `https://vault.int.<domain>` | Secrets management, PKI |
| Harbor | `https://harbor.int.<domain>` | OCI registry, pull-through proxy cache |
| MinIO console | `https://minio.int.<domain>` | S3-compatible object storage console |
| Grafana | `https://grafana.int.<domain>` | Dashboards and alerting |

Harbor and MinIO are present on self-hosted (on-prem) Tooling Clusters. Cloud Tooling Clusters may use managed equivalents (S3, ECR/GHCR) — see [Provider Model](../architecture/provider-model.md).

---

## Next

- Deploy a Switch that pulls from this Tooling Cluster: [Deploy a Switch](deployment-sw.md)
- Push an updated GitOps artifact: [Building artifacts](../platform/building-artifacts.md)
- Back up Vault and MinIO: [Backup and restore](../operations/backup-restore.md)
