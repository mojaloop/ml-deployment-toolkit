# Proxmox infrastructure setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / Proxmox

**Audiences:** adopter (deploy)

What to provision in Proxmox VE before deploying a Tooling Cluster or a Switch. The same setup applies to both cluster types — only `config.yaml` differs.

For background on how Proxmox maps to the platform stack (Talos, Cilium, OpenEBS, LB-IPAM), see [Provider Model](../../architecture/provider-model.md).

---

## Required PVE state

- A Proxmox VE cluster (single node is fine) reachable over HTTPS on its API port (default `8006`)
- A storage pool that supports VM disks (`local-lvm`, ZFS, Ceph RBD — must support raw or qcow2 images)
- A storage pool that supports ISOs/images and snippets (typically `local`)
- A bridge interface attached to the network you want VMs on (typically `vmbr0`)
- SSH access to each Proxmox node for the user that owns the API token

---

## API token

Create a token the toolkit will use to manage VMs. Run on a PVE node:

```bash
# Create the token (privilege separation off so the token inherits user ACLs)
pveum user token add root@pam 'ml-deployment-toolkit' --privsep 0

# Grant the token Administrator on the whole datacenter
pveum acl modify / -token 'root@pam!ml-deployment-toolkit' -role Administrator
```

The first command prints the token secret once — save it. The full token ID has the form `root@pam!ml-deployment-toolkit=<uuid>`.

Put the value in `config/environments/<env>/.env`:

```bash
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006"
PROXMOX_VE_API_TOKEN="root@pam!ml-deployment-toolkit=<uuid>"
PROXMOX_VE_INSECURE="true"    # set false if PVE uses a CA-signed cert
```

A scoped non-root user is also acceptable — grant it `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Console`, `Datastore.AllocateSpace`, `Datastore.Audit`, `SDN.Use`, `Sys.Audit` on the relevant paths. Administrator is the simplest and matches the example above.

---

## SSH access

The toolkit uploads the Talos image and cloud-init snippets over SSH. Provide credentials for an account that can write to the snippets datastore:

```bash
PROXMOX_VE_SSH_USERNAME="root"
PROXMOX_VE_SSH_PASSWORD="<password>"
```

Key-based auth (`PROXMOX_VE_SSH_AGENT="true"` + a loaded SSH agent) is also supported.

---

## Storage pools

The toolkit reads pool names from `config.yaml`:

```yaml
infra:
  proxmox:
    storage:
      disks: "local-lvm"      # VM root + data disks (must support raw)
      images: "local"          # Talos ISO/qcow upload target
      snippets: "local"        # cloud-init snippets
```

Verify the pools exist and have the expected content types in **Datacenter → Storage**. The `disks` pool needs `Disk image` enabled; `images` needs `ISO image`; `snippets` needs `Snippets`.

---

## Network and IP plan

Plan IPs before deploying. A cluster needs:

| Purpose | Count | Notes |
|---------|-------|-------|
| K8s API VIP | 1 | `cluster.vip` — floating IP, must be in the same L2 as nodes |
| Node IPs | 1 per VM | Assigned by Talos via DHCP or static. Sizing profile drives count |
| LB-IPAM range | 2 (CC) or 3 (SW) | `app.lb_ipam.range` — CC needs `gw-int`+`gw-ext`; SW adds `gw-extapi` for DFSP mTLS |

All IPs must be on the bridge configured in `config.yaml > infra.proxmox.network_bridge` (default `vmbr0`).

---

## Placement groups

`config.yaml > infra.proxmox.placement` maps logical placement groups (used by the sizing profile to distribute control-plane and worker VMs across failure domains) to physical PVE node names:

```yaml
infra:
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"
      placement-group-3: "node2"   # only if your sizing profile uses 3 groups
```

The CC `small` profile uses 2 placement groups; the SW `tps-1` profile uses 3. Check the profile under `config/providers/proxmox/profiles/{cc,env}/<profile>.yaml` for the exact count.

---

## Next

- Set up your DNS provider — see [DNS provider setup](index.md#dns-providers)
- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
