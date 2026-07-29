# ml-deployment-toolkit

An infrastructure-agnostic distribution of [Mojaloop](https://mojaloop.io/) — the open-source real-time payment switch. The toolkit packages Terraform modules and FluxCD GitOps manifests into OCI artifacts, so a full Mojaloop deployment becomes a single `make plan-apply` against the infrastructure provider of your choice (Proxmox/Talos on-prem, AWS EKS, DigitalOcean DOKS).

## What you can deploy

Two cluster kinds, each driven from its own environment config under `environments/<env>/`.

### Tooling Cluster (`role: cc`)

A management-plane cluster hosting the shared services that the rest of the platform depends on: Harbor (OCI registry and pull-through cache), Vault (secrets and PKI), MinIO or managed object storage (state and backups), FluxCD, and the observability stack. A Tooling Cluster is optional — a Hub can pull artifacts from a public OCI registry and send telemetry anywhere — but recommended for multi-environment setups and air-gapped operation.

→ [Deploy a Tooling Cluster](doc/adopter/deploy/tooling-cluster.md)

### Hub / Switch (`role: env`)

A cluster running Mojaloop itself: central ledger, account lookup, quoting, settlements, MCM, the Ory auth stack, and the data layer (MySQL, Kafka, MongoDB, Redis — in-cluster or external). DFSPs connect to it over mTLS via the Cilium-based gateway.

→ [Deploy a Hub](doc/adopter/deploy/hub.md)

## Quick start

Before your first deployment you need a provider account, DNS zone, and a few CLI tools installed — see [prerequisites](doc/adopter/deploy/prerequisites.md) and [provider setup](doc/adopter/deploy/provider-setup.md).

```bash
# 1. Create the environment from a sample
mkdir -p environments/<env>
cp environments/mlf-lab1-cc1/config.yaml.sample environments/<env>/config.yaml
cp environments/mlf-lab1-cc1/.env.sample       environments/<env>/.env

# 2. Choose capabilities, template, and parameters
$EDITOR environments/<env>/config.yaml

# 3. Supply external credentials only — internal service passwords are generated
$EDITOR environments/<env>/.env

# 4. Check it before spending time on a deploy
make validate ENV=<env>

# 5. Deploy
make plan-apply ENV=<env>
```

Afterwards:

```bash
make secrets ENV=<env>        # generated internal passwords (Harbor, MinIO, DBs, ...)
make apply-config ENV=<env>   # push config changes in seconds, without touching VMs
```

## How it is organised

| Path | Contents |
|---|---|
| `environments/<env>/` | Your deployment: `config.yaml`, `.env`, optional `values/<chart>.yaml` overrides |
| `config/templates/` | Deployment templates (capacity + tuning) and per-provider machine mappings |
| `config/schemas/` | JSON Schemas — editor autocomplete and `make validate` |
| `src/infra/` | Terraform stack: cluster VMs / managed Kubernetes + Flux bootstrap |
| `src/config/` | Terraform stack: everything Flux consumes (config, secrets, Kustomizations) |
| `gitops/` | The distribution artifact — environment-neutral manifests |

Configuration and infrastructure are separate Terraform stacks with separate state, so a config change is a fast, low-risk `make apply-config` that cannot touch running VMs.

## Documentation

Full guide — architecture, adopter, platform, operations, participant — is in [doc/](doc/index.md).
