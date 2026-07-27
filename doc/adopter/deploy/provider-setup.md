# Provider Setup

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Provider setup

**Audiences:** adopter (deploy)

What to prepare in Proxmox and DNS before deploying. The same setup serves a Tooling Cluster and a Hub — only `config.yaml` differs.

- [Proxmox state](#proxmox-state)
- [API token](#api-token)
- [SSH access](#ssh-access)
- [Storage pools](#storage-pools)
- [Network and IP plan](#network-and-ip-plan)
- [Placement groups](#placement-groups)
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

> **TLS verification is always off.** The Proxmox provider is configured with `insecure = true` and it is not overridable — `PROXMOX_VE_INSECURE` in `.env` has no effect. If the Proxmox host uses a CA-signed certificate, verification is skipped anyway. Tracked in `discrepancies.md` item D2.

## SSH access

The toolkit uploads the Talos image and cloud-init snippets over SSH. Provide an account that can write to the snippets datastore:

```bash
PROXMOX_VE_SSH_USERNAME="root"
PROXMOX_VE_SSH_PASSWORD="<password>"
```

Password authentication is what the provider uses. SSH-agent auth is not available — the provider is configured with `agent = false` and it is not overridable (same tracking item as above).

## Storage pools

The toolkit reads pool names from `config.yaml`:

```yaml
infra:
  proxmox:
    storage:
      disks: "local-lvm"      # VM disks — must support raw images
      images: "local"          # Talos image upload target
      snippets: "local"        # cloud-init snippets
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
| Node IPs | 1 per VM | Assigned by Talos; the sizing profile sets the count |
| LB-IPAM range | 2 or 3 | `app.lb_ipam.range` |

**The LB range differs by role.** A Tooling Cluster needs 2 addresses (`gw-int`, `gw-ext`). A Hub needs 3 — it adds the FSPIOP endpoint. The range must sit outside the DHCP scope; overlap causes intermittent failures as addresses are handed out twice.

All addresses must be on the bridge in `infra.proxmox.network_bridge`.

## Placement groups

`infra.proxmox.placement` maps logical placement groups — used by the sizing profile to spread VMs across failure domains — to physical node names:

```yaml
infra:
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"
      placement-group-3: "node2"   # only if the profile uses three
```

How many groups a profile uses is in `config/providers/proxmox/profiles/{cc,env}/<profile>.yaml`. Provide a node mapping for each group the profile references.

## DNS zone

The adopter needs a delegated zone the toolkit can manage. `external-dns` creates and updates records automatically — **do not pre-create records for cluster services**, as hand-created records cause ownership conflicts.

Set the credential for the chosen provider in `.env`:

| Provider | Variable(s) |
|----------|-------------|
| Route53 | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
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
