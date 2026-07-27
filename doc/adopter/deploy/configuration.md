# Configuration

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Configuration

**Audiences:** adopter (deploy)

Two files describe an environment: `config.yaml` for infrastructure and `.env` for secrets. Everything specific to a deployment lives in these; the adopter never edits the distribution.

- [Vocabulary](#vocabulary)
- [Environment layout](#environment-layout)
- [config.yaml](#configyaml)
- [Secrets](#secrets)
- [Helm value overrides](#helm-value-overrides)

## Vocabulary

The documentation uses reader-facing names; the configuration uses code values. They map one to one:

| Configuration value | The docs call it |
|---------------------|------------------|
| `role: cc` | Tooling Cluster |
| `role: env` | Hub |
| `dfsp`, `DFSP_ID` | Participant |

When a page says "deploy a Hub," set `role: env`. This is the only translation needed.

## Environment layout

Each environment is a directory under `config/environments/`. `ENV=` selects it.

```
config/environments/
  my-cc/
    config.yaml        # infrastructure and cluster config
    .env               # secrets (git-ignored)
    values/            # optional Helm overrides (git-ignored)
```

Environments are fully independent — their own config, secrets, and Terraform state. One repository clone manages any number of them. A Tooling Cluster and its Hubs are separate environments, each deployed with its own `make plan-apply ENV=<name>`.

State and generated artifacts land under `artifacts/<env>/` — see [System overview](../../architecture/system-overview.md#configuration-tiers).

> **`config/environments/` is git-ignored in full.** A fresh clone contains no environments and no sample files to copy. This is a known gap — `discrepancies.md` item D1. Until it is resolved, obtain the sample files from an existing deployment or the platform team.

## config.yaml

The complete schema, from a Tooling Cluster:

```yaml
infra:
  provider: "proxmox"
  proxmox:
    placement:
      placement-group-1: "node0"      # anti-affinity groups → Proxmox nodes
      placement-group-2: "node1"
    network_bridge: "vmbr0"
    storage:
      disks: "local-lvm"              # VM disks
      images: "local"                 # boot images
      snippets: "local"               # cloud-init — needs Snippets content type

profile: "small"                      # sizing — see below

cluster:
  name: "my-cc"
  role: "cc"                          # cc (Tooling Cluster) | env (Hub)
  vip: "192.168.88.10"                # floating control-plane IP
  flux:
    version: "2.7.2"

dns:
  provider: "digitalocean"            # digitalocean | cloudflare | route53
  domain: "cc1.example.com"

app:
  lb_ipam:
    range: "192.168.88.11-192.168.88.12"   # LB address pool
  alert_email: "ops@example.com"

oci:
  repo:
    active: true
    url: "oci://ghcr.io/<org>/ml-deployment-toolkit"
    version: "latest"                 # "latest" or a pinned tag
  proxy:
    active: false                     # Harbor pull-through cache
    url: "harbor.int.cc1.example.com"
```

A few fields decide the shape of everything else:

| Field | Effect |
|-------|--------|
| `cluster.role` | Which Kustomizations deploy — `cc` or `env` |
| `profile` | Node count and machine sizing |
| `dns.provider` | Which DNS integration is configured |
| `oci.repo.version` | `latest` follows publishes; a tag pins |

**Address counts differ by role.** A Tooling Cluster needs two LB addresses; a Hub needs three, because it also has the FSPIOP endpoint. See [Networking](../../architecture/networking.md#load-balancer-addresses).

### Sizing profiles

`profile` names a sizing definition from `config/providers/proxmox/profiles/`:

| Role | Profiles |
|------|----------|
| Tooling Cluster (`cc`) | `small`, `medium` |
| Hub (`env`) | `tps-1`, `tps-10` |

Hub profiles are named for the transactions-per-second they are sized to sustain. Rationale in [ADR-012](../../architecture/decisions/012-tps-sizing-profiles.md).

## Secrets

`.env` holds credentials. The Makefile maps clean names to `TF_VAR_*` — no prefixes needed, except where a provider reads a variable natively (Proxmox and the DNS tokens).

```bash
$EDITOR config/environments/<env>/.env
```

The required set depends on the role. It is listed in full in [Prerequisites → Credentials checklist](prerequisites.md#credentials-checklist) — that is the single source for which secrets each role needs, and it is not duplicated here.

Two things worth repeating because they fail quietly:

- **Alerting needs its delivery secrets.** Rules run regardless, but nothing is sent without them.
- **Proxmox variables are read natively** by the provider — `PROXMOX_VE_*` are used as-is, not mapped through `TF_VAR_`.

## Helm value overrides

The adopter can override the platform's Helm values for the Mojaloop and MCM charts without forking anything. Drop a file in `values/`:

```
config/environments/<env>/values/
  mojaloop.yaml
  mcm.yaml
```

Each is layered over the platform defaults through the HelmRelease's `valuesFrom` as an optional ConfigMap — a missing file changes nothing. Merge order is chart defaults, then platform values, then the environment's file.

Two constraints:

- **Only `mojaloop` and `mcm` are wired for overrides.** Other charts cannot be overridden this way.
- **Flux substitution variables are not expanded** inside these files — `${...}` is taken literally. Hardcode the required values.

Apply changes with `make plan-apply ENV=<env>`; Flux picks them up on the next reconcile. This is configuration, not customization — changing the distribution itself is the [Integrator](../../integrator/index.md) guide.

Next: [Deployment](deployment.md).
