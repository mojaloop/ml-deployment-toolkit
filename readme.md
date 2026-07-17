# ml-deployment-toolkit

An infrastructure-agnostic distribution of [Mojaloop](https://mojaloop.io/) — the open-source real-time payment switch. The toolkit packages Terraform modules and FluxCD GitOps manifests into OCI artifacts, so a full Mojaloop deployment becomes a single `make plan-apply` against the infrastructure provider of your choice (Proxmox/Talos on-prem, AWS EKS, DigitalOcean DOKS).

## What you can deploy

Two cluster kinds, each driven from its own environment config under `config/environments/<env>/`.

### Tooling Cluster (CC)

A management-plane cluster hosting the shared services that the rest of the platform depends on: Harbor (OCI registry and pull-through cache), Vault (secrets and PKI), MinIO or managed object storage (state and backups), FluxCD, and the observability stack. A Tooling Cluster is optional — a single Switch can pull artifacts directly from a public OCI registry — but recommended for multi-environment setups and air-gapped operation.

→ [Deploy a Tooling Cluster](docs/adopter/deployment-cc.md)

### Switch (SW)

An App Environment cluster running Mojaloop itself: central ledger, account lookup, quoting, settlements, MCM, the auth stack (Keycloak + Ory), and the data layer (MySQL, Kafka, MongoDB, Redis). DFSPs connect to it over mTLS via the Cilium-based gateway.

→ [Deploy a Switch](docs/adopter/deployment-sw.md)

## Quick start

Before your first deployment you need a provider account, DNS zone, and a few CLI tools installed — see [prerequisites](docs/adopter/prerequisites.md) and [provider setup](docs/adopter/provider-setup/index.md).


```bash
# 1. Pick an environment name and create its config dir
cp -r config/environments/ml-cc config/environments/<env>

# 2. Fill in credentials
cp config/environments/<env>/.env.sample config/environments/<env>/.env
$EDITOR config/environments/<env>/.env

# 3. Edit cluster, provider, DNS, and sizing
$EDITOR config/environments/<env>/config.yaml

# 4. Plan and apply
make plan-apply ENV=<env>
```

## Documentation

Full guide — architecture, adopter, platform, operations, participant — is in [docs/](docs/index.md).
