# Provider Setup

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Provider setup

**Audiences:** adopter (deploy)

What to prepare in Proxmox and DNS before deploying. The same setup serves a Tooling Cluster and a Hub — only the environment's configuration differs.

- [Proxmox state](#proxmox-state)
- [API token](#api-token)
- [SSH access](#ssh-access)
- [Storage pools](#storage-pools)
- [Network and IP plan](#network-and-ip-plan)
- [Placement groups](#placement-groups)
- [Talos node facts](#talos-node-facts)
- [DNS zone](#dns-zone)

## Proxmox state

Before deploying, the adopter needs:

- A Proxmox VE cluster — a single node is fine — reachable over HTTPS on its API port (default `8006`)
- A storage pool for VM disks (`local-lvm`, ZFS, or Ceph RBD)
- A storage pool for images and snippets (typically `local`)
- A bridge on the VM network (typically `vmbr0`)
- SSH access to each node for the token-owning user

## API token

Create a token for the toolkit. On a Proxmox node:

```bash
pveum user token add root@pam 'ml-deployment-toolkit' --privsep 0
pveum acl modify / -token 'root@pam!ml-deployment-toolkit' -role Administrator
```

The first command prints the secret once — save it. The full token ID is `root@pam!ml-deployment-toolkit=<uuid>`.

Into `.env`:

```bash
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006"
PROXMOX_VE_API_TOKEN="root@pam!ml-deployment-toolkit=<uuid>"
```

A scoped non-root user works too — grant `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Console`, `Datastore.AllocateSpace`, `Datastore.Audit`, `SDN.Use`, `Sys.Audit`. Administrator is simplest.

> **TLS verification is always off.** The Proxmox provider is configured with `insecure = true` in `src/infra/providers.tf` and it is not overridable from configuration. If the Proxmox host uses a CA-signed certificate, verification is skipped anyway.

## SSH access

The toolkit uploads the Talos image and cloud-init snippets over SSH. Provide an account that can write to the snippets datastore:

```bash
PROXMOX_VE_SSH_USERNAME="root"
PROXMOX_VE_SSH_PASSWORD="<password>"
```

Password authentication is what the provider uses. SSH-agent auth is not available — the provider is configured with `agent = false` and it is not overridable from configuration.

## Storage pools

The toolkit reads pool names from the environment's `proxmox/proxmox.yaml` — the sidecar file holding the Proxmox facts, beside `config.yaml` ([Configuration → Environment layout](configuration.md#environment-layout)):

```yaml
# ../environments/<env>/proxmox/proxmox.yaml
version: 1
network_bridge: "vmbr0"
storage:
  disks: "local-lvm"          # VM disks — must support raw images
  images: "local"             # Talos image upload target
  snippets: "local"           # cloud-init snippets
```

Confirm each pool exists with the right content type in **Datacenter → Storage**: `disks` needs `Disk image`, `images` needs `ISO image`, `snippets` needs `Snippets`.

**`Snippets` is off by default on `local`, and deployment fails without it** when uploading cloud-init. Enable it on each node:

```bash
pvesm set local --content iso,vztmpl,backup,snippets
```

The content list is **absolute, not additive** — include the existing types, or the command drops them. Check the current value first:

```bash
pvesm status --storage local
```

## Network and IP plan

Plan addresses before deploying:

| Purpose | Count | Notes |
|---------|-------|-------|
| Kubernetes API VIP | 1 | `cluster.vip` — floating IP, same L2 as the nodes |
| Node IPs | 1 per VM | Leased over DHCP on the configured bridge; the deployment template sets the count |
| LB-IPAM pools | 2 or 4 | `cluster.lb_ipam.pools` — one address per gateway |

**The pool count differs by role.** A Tooling Cluster needs 2 addresses (`gw-int`, `gw-ext`). A Hub needs 4 — it adds the FSPIOP endpoints (`gw-extapi`, `gw-intapi`). Every address must sit outside the DHCP scope; overlap causes intermittent failures as addresses are handed out twice. Because each gateway's address is fixed in config, firewall rules can be written before the cluster exists.

All addresses must be on the bridge named by `network_bridge` in the environment's `proxmox/proxmox.yaml`.

## Placement groups

The environment's `placement.yaml` maps logical placement groups — used by the deployment template to spread VMs across failure domains — to physical node names:

```yaml
# ../environments/<env>/placement.yaml
version: 1
placement:
  pg-1: "node0"
  pg-2: "node1"
  pg-3: "node2"   # only if the template uses three
```

Which groups a template references is in `providers/proxmox/templates/{tooling,hub,bare}/<template>/placement.yaml`, in each node pool's `placement:` list. Provide a node mapping for every group named there; an unmapped `pg-N` fails the plan before anything is created.

On AWS the same file maps placement groups to **availability zones** instead of physical nodes (`pg-1: "eu-west-1a"`). Each pool then materializes as one single-AZ EKS managed node group per distinct placement entry — EKS has no per-instance placement, so the split is how the on-prem wrapping rule (node *i* takes `placement[i]`) is honored with a guarantee. The file is optional on AWS: without it, every pool is a single node group spread best-effort by the autoscaling group across the region's first three AZs. Once present, every group the template references must be mapped, exactly as on-prem. Adding or removing the file on a live cluster renames the node groups and therefore rolls their nodes — decide before first deploy where possible.

The same file defines the node pools themselves. A pool's name doubles as its Kubernetes placement identity — every node it expands to is labelled `node-role=<pool name>` mechanically, and a pool that should repel other workloads declares its own `taints:` there. The distribution schedules against pools with soft affinity, so a template without a given pool still runs everything — see [Provider model → Pool names are the placement contract](../../architecture/provider-model.md#pool-names-are-the-placement-contract). The environment's `placement.yaml` may also override the template's pools by name — a partial entry (say, a `count` bump) inherits the rest, `enabled: false` drops a default pool, and an unknown name adds an extra one.

## Talos node facts

The environment's `talos.yaml` — beside `config.yaml`, like the other sidecar files — carries the node OS facts only the on-prem machine-config path reads. Both keys are optional; omitted, the nodes use their DHCP-provided defaults:

```yaml
# ../environments/<env>/talos.yaml
version: 1
nameservers: ["8.8.8.8", "1.1.1.1"]
ntp_servers: ["time.cloudflare.com"]
```

Per-pool Talos machine-config fragments — kubelet settings, sysctls, and similar — go in `talos/<pool>.yaml`, applied to every node of that pool after the template's own fragment ([Configuration → Environment layout](configuration.md#environment-layout)).

## DNS zone

The adopter needs a delegated zone the toolkit can manage. `external-dns` creates and updates records automatically — **do not pre-create records for cluster services**, as hand-created records cause ownership conflicts.

Set the credential for the chosen provider in `.env`:

| Provider | Variable(s) |
|----------|-------------|
| Route53 | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |
| Cloudflare | `CLOUDFLARE_API_TOKEN` (scope `Zone:DNS:Edit`) |
| DigitalOcean | `DIGITALOCEAN_TOKEN` |

Set the zone in `config.yaml`:

```yaml
dns:
  provider: "cloudflare"
  domain: "cc1.example.com"
```

The zone must be delegated to the provider before deploying — the toolkit manages records within it, but does not create the zone or its delegation. Confirm delegation resolves before deploying; certificate issuance depends on it.

Next: [Configuration](configuration.md), then [Deployment](deployment.md).
