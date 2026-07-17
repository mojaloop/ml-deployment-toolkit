# Deploy a Switch (SW)

[docs](../index.md) / [adopter](index.md) / Deploy a Switch

**Audiences:** adopter (deploy)

A Switch is an App Environment cluster running Mojaloop itself: central ledger, account lookup, quoting, settlements, MCM, the auth stack (Keycloak + Ory), and the data layer (MySQL/PXC, Kafka, MongoDB, Redis). DFSPs connect to it over mTLS via the Cilium-based gateway.

A Switch is sized by a TPS-based profile (`tps-1`, `tps-500`, etc.) and typically references a Tooling Cluster for OCI artifact storage, Harbor pull-through cache, S3-compatible backup storage, and the observability backends. Standalone Switches that pull from a public OCI registry are also supported.

This page covers what's specific to an SW deployment. For the shared `make plan-apply` workflow, commands reference, and destroy, see [Deployment](deployment.md).

---

## Before you start

- A reachable Tooling Cluster (or a public OCI registry the Switch can pull from)
- Provider account and credentials — see [provider setup](provider-setup/index.md)
- DNS zone delegated to your DNS provider — see [DNS provider setup](provider-setup/index.md)
- Environment scaffolded under `config/environments/<env>/` — see [Configuration](configuration.md)

---

## Configure

The Switch uses a TPS-based sizing profile and adds `backup`, `observability`, and `app.api_type` on top of the shared schema. `oci.proxy.active` typically points at the Tooling Cluster's Harbor.

Minimal `config.yaml` shape:

```yaml
infra:
  provider: "proxmox"          # or aws, digitalocean
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"
      placement-group-3: "node2"
    network_bridge: "vmbr0"
    storage: { disks: "local-lvm", images: "local", snippets: "local" }

profile: "tps-1"               # Switch sizing profile (config/providers/<provider>/profiles/env/)

cluster:
  name: "ml-sw"
  role: "env"                  # routes Flux to deploy gitops/env/, env-data/, env-auth/, env-app/
  vip: "192.168.88.14"         # on-prem only — floating IP for the K8s API

dns:
  provider: "digitalocean"
  domain: "sw1.example.com"

app:
  lb_ipam:
    range: "192.168.88.37-192.168.88.39"   # needs 3 IPs: gw-int, gw-ext, gw-extapi
  alert_email: "ops@example.com"
  api_type: "fspiop"            # fspiop | iso20022 — set once at deploy, do not change mid-flight

backup:
  s3:
    endpoint: "https://s3.int.<cc-domain>"
    bucket: "backups"
    region: "us-east-1"

observability:
  loki_url: "https://loki.int.<cc-domain>/loki/api/v1/push"
  mimir_url: "https://thanos.int.<cc-domain>/api/v1/receive"

oci:
  repo:
    active: true
    url: "oci://ghcr.io/<org>/ml-deployment-toolkit"      # or oci://harbor.int.<cc-domain>/ml-deployment-toolkit
    version: "latest"
  proxy:
    active: true
    url: "harbor.int.<cc-domain>"            # Talos-level containerd mirror
```

Required `.env` secrets in `config/environments/<env>/.env`:

- Provider credentials (`PROXMOX_VE_*`, `AWS_*`, or `DIGITALOCEAN_TOKEN`)
- DNS credentials (`DIGITALOCEAN_TOKEN`, `CLOUDFLARE_API_TOKEN`, or `AWS_*`)
- OCI repo + proxy credentials (`OCI_REPO_*`, `OCI_PROXY_*`)
- OIDC client secrets (`HUBOP_OIDC_SECRET`, `MCM_OIDC_CLIENT_SECRET`, `DFSP_OIDC_CLIENT_SECRET`, `ROLE_ASSIGN_SVC_SECRET`)
- SMTP credentials for Keycloak DFSP invitations (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`)
- Backup S3 credentials (`BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`)

Full schema and secrets reference: [Configuration](configuration.md).

---

## Deploy

```bash
make plan-apply ENV=<env>
```

See [Deployment](deployment.md#plan-and-apply) for what happens during apply.

---

## Verify

Run the shared checks in [Deployment > Verify](deployment.md#verify) first, then the SW-specific checks below.

```bash
export KUBECONFIG=$(pwd)/artifacts/<env>/kubernetes/kubeconfig

# Mojaloop HelmRelease should be Ready
kubectl get helmrelease -n mojaloop

# Data layer operators and clusters
kubectl get perconaxtradbcluster -n mojaloop      # MySQL (PXC)
kubectl get kafka -n mojaloop                      # Kafka (Strimzi)
kubectl get perconaservermongodb -n mojaloop       # MongoDB

# Auth stack
kubectl get pods -n auth

# Gateways should have addresses (3 LB IPs: gw-int, gw-ext, gw-extapi)
kubectl get gateways -n platform-system

# All Kustomizations should be Ready
kubectl get kustomizations -n flux-system
```

Mojaloop reconciliation depends on the data layer being healthy first (PXC, Kafka, Mongo). Allow several minutes after Flux marks `env-data` as Ready before `env-app` finishes.

---

## Harbor proxy cache

When `oci.proxy.active: true`, the Switch pulls container images through the Tooling Cluster's Harbor instance. Harbor acts as a transparent pull-through cache — images are fetched from upstream registries on first pull and cached for subsequent requests.

This is configured at the Talos machine level (containerd registry mirrors), so all image pulls are transparently routed through Harbor without changes to Helm charts or pod specs.

### Verify proxy cache is working

```bash
# Check that nodes have registry mirrors configured (Talos)
talosctl get registries.mirrors

# Pull an image and verify it appears in Harbor's proxy cache projects
kubectl run test --image=nginx:latest --restart=Never
kubectl delete pod test
```

In Harbor's web UI, proxy cache projects show cached images with their upstream source and pull count.

---

## Next

- Connect a DFSP to this Switch: [Participant guide](../participant/index.md)
- Read dashboards and investigate alerts: [Monitoring](../operations/monitoring.md)
- Restore from backup: [Backup and restore](../operations/backup-restore.md)
- Upgrade the Switch: [Upgrading](upgrading.md)
