# Prerequisites

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Prerequisites

**Audiences:** adopter (deploy)

Everything you need in place before your first `make plan-apply`. For what gets deployed and why, see [System overview](../../architecture/system-overview.md).

- [Tools](#tools)
- [Proxmox](#proxmox)
- [DNS](#dns)
- [OCI registry](#oci-registry)
- [Credentials checklist](#credentials-checklist)

## Tools

Install these on the machine you deploy from.

| Tool | Version | Used for |
|------|---------|----------|
| Terraform | ≥ 1.0 | Provisioning — Make wraps it |
| kubectl | ≥ 1.28 | Cluster access and verification |
| Flux CLI | ≥ 2.0 | Inspecting and forcing reconciliation |
| talosctl | latest | Talos node access and health (self-managed clusters) |
| make | any | Runs the workflow; pre-installed on macOS and Linux |

For working on the distribution itself — building artifacts, rendering manifests — you also need `helm`, `jsonnet`, and `jb`. Those belong to the [Platform](../../platform/index.md) guide, not to deploying.

## Proxmox

Proxmox with Talos Linux is the supported infrastructure. You need:

- **API access** — an API token (preferred) or user/password
- **SSH access** to the Proxmox nodes
- **A VM storage pool** for disks and images
- **The `Snippets` content type enabled** on the pool used for cloud-init — this is off by default and provisioning fails without it

Full walkthrough: [Provider setup](provider-setup.md).

## DNS

Your DNS provider is independent of your infrastructure — any of the three works with Proxmox.

| Provider | Credential | Env variable |
|----------|-----------|--------------|
| Route53 | Access key with Route53 permissions | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Cloudflare | Token scoped to `Zone:DNS:Edit` | `CLOUDFLARE_API_TOKEN` |
| DigitalOcean | Token with DNS write scope | `DIGITALOCEAN_TOKEN` |

You need a delegated DNS zone the toolkit can manage — `external-dns` creates and updates records in it automatically. See [Provider setup](provider-setup.md#dns-zone).

## OCI registry

Flux reconciles from an OCI artifact. What you need depends on where it lives.

**Pulling a public artifact** — no credentials. Public GitHub Container Registry artifacts pull anonymously.

**Private registry, or publishing your own** — set `OCI_REPO_USERNAME` and `OCI_REPO_PASSWORD`. For GitHub Container Registry, the password is a Personal Access Token:

```bash
gh auth refresh -s read:packages,write:packages
gh auth token
```

Use your GitHub username and the token output.

**Harbor pull-through cache** — only if you run a Tooling Cluster with the proxy enabled (`oci.proxy.active: true`). Set `OCI_PROXY_USERNAME` and `OCI_PROXY_PASSWORD`.

## Credentials checklist

Credentials live in your environment's `.env`. The set depends on the cluster role — the full reference is in [Configuration](configuration.md#secrets), but check these before you start, because a missing one fails late and quietly rather than at plan time.

**Every cluster:**

- Proxmox — `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`, `PROXMOX_VE_SSH_PASSWORD`
- DNS — the variable for your provider, above
- OCI — `OCI_REPO_USERNAME`, `OCI_REPO_PASSWORD` if not pulling anonymously

**Tooling Cluster (`cc`):**

- `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `HARBOR_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`
- `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`
- **Alerting delivery** — `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `ALERT_EMAIL_FROM`, `ALERT_EMAIL_TO`, and optionally `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`. **Without these, 22 alert rules evaluate but nothing is delivered** — the most common way a deployment ends up believing it has no alerting. See [Observability](../../architecture/observability.md#alerting).

**Hub (`env`):**

- Database — `MYSQL_ROOT_PASSWORD`, `MYSQL_CENTRAL_LEDGER_PASSWORD`, `MYSQL_ACCOUNT_LOOKUP_PASSWORD`, `MYSQL_ORACLE_MSISDN_PASSWORD`, `MONGODB_ROOT_PASSWORD`, `MONGODB_APP_PASSWORD`
- Auth — `KRATOS_DB_PASSWORD`, `KETO_DB_PASSWORD`, `HYDRA_DB_PASSWORD`, `MCM_DB_PASSWORD`
- Identity — `HUB_ADMIN_EMAIL`, `HUB_ADMIN_PASSWORD`, `HUBOP_OIDC_SECRET`, `MCM_OIDC_CLIENT_SECRET`, `ROLE_ASSIGN_SVC_SECRET`

Next: [Provider setup](provider-setup.md).
