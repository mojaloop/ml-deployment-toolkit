# Prerequisites

[docs](../index.md) / [adopter](index.md) / Prerequisites

**Audiences:** adopter (deploy)

Everything you need before running your first `make plan-apply`. For an overview of what gets deployed and why, see the [System Overview](../architecture/system-overview.md).

## Required tools

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| Terraform | >= 1.0 | Infrastructure provisioning | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| Flux CLI | >= 2.0 | GitOps debugging and management | [fluxcd.io](https://fluxcd.io/flux/cmd/) |
| kubectl | >= 1.28 | Kubernetes cluster access | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| GitHub CLI | latest | OCI authentication (optional) | [cli.github.com](https://cli.github.com/) |
| make | any | Build automation (wraps Terraform) | Pre-installed on macOS/Linux |

## Infrastructure provider requirements

You need credentials for one infrastructure provider. Choose the provider that matches your deployment target.

| Provider | Requirements |
|----------|-------------|
| Proxmox | Proxmox VE API access (token or password), SSH access to nodes, at least one available VM storage pool |
| AWS | AWS CLI configured, IAM user or role with permissions for EKS, VPC, EC2, and IAM |
| DigitalOcean | API token with read/write scope |
| GCP | gcloud CLI configured, service account with permissions for GKE and VPC |

For details on how providers map to platform components (CNI, storage, load balancing), see [Provider Model](../architecture/provider-model.md).

## DNS provider requirements

The DNS provider is an independent dimension from the infrastructure provider -- you can use any combination (e.g., Proxmox with Cloudflare DNS, AWS with DigitalOcean DNS). You need API credentials for whichever DNS provider you choose.

| DNS provider | Credential | Environment variable |
|-------------|------------|---------------------|
| DigitalOcean | API token with DNS write scope | `DIGITALOCEAN_TOKEN` |
| Cloudflare | API token with Zone:DNS:Edit permission | `CLOUDFLARE_API_TOKEN` |
| Route53 | AWS access key with Route53 permissions | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| PowerDNS | API URL and key | `POWERDNS_API_URL` + `POWERDNS_API_KEY` |

DNS credentials go in your environment's `.env` file. See [Configuration](configuration.md) for the full secrets reference.

## OCI registry access

ML Deployment Toolkit uses OCI artifacts for distributing GitOps manifests via FluxCD. Your access requirements depend on your setup.

### Public GHCR packages (pull only)

No credentials needed. Public OCI artifacts on GitHub Container Registry can be pulled without authentication.

### Private registries or push access

Set `OCI_REPO_USERNAME` and `OCI_REPO_PASSWORD` in your `.env` file. For GitHub Container Registry, use a Personal Access Token (PAT) as the password.

**Generate a GitHub PAT with the required scopes:**

```bash
# Refresh your GitHub CLI token with package scopes
gh auth refresh -s read:packages,write:packages

# Retrieve the token
gh auth token
```

Use your GitHub username as `OCI_REPO_USERNAME` and the token output as `OCI_REPO_PASSWORD`.

### Pull-through cache (optional)

If your environment uses a Harbor pull-through cache for container images (`oci.proxy.active: true` in `config.yaml`), set `OCI_PROXY_USERNAME` and `OCI_PROXY_PASSWORD` for Harbor authentication. This is only relevant when running a Tooling Cluster with Harbor.

## Tooling Cluster requirements (optional)

The Tooling Cluster provides centralized services (Harbor OCI registry, Vault secrets management, MinIO object storage, observability stack) for multi-environment deployments. It is optional -- a single App Environment cluster can pull artifacts directly from an external OCI registry.

If deploying a Tooling Cluster, you also need:

- **MinIO credentials** (`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`) for on-prem object storage
- **Harbor admin password** (`HARBOR_ADMIN_PASSWORD`) for the OCI registry
- **Grafana admin password** (`GRAFANA_ADMIN_PASSWORD`) for the observability dashboard

These are documented in the `.env.sample` file and covered in [Configuration](configuration.md).

## Next step

Once you have the tools installed and credentials ready, proceed to [Configuration](configuration.md) to set up your environment files.
