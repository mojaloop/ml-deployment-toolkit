# Provider setup

[docs](../../index.md) / [adopter](../index.md) / Provider setup

**Audiences:** adopter (deploy)

How to provision the accounts, tokens, and DNS zones the toolkit expects, per provider. For the list of *what* you need (tools and credentials), see [Prerequisites](../prerequisites.md). For deploying once setup is complete, see [Deploy a Tooling Cluster](../deployment-cc.md) or [Deploy a Switch](../deployment-sw.md).

Infrastructure provider and DNS provider are independent dimensions — you can mix any combination (for example, Proxmox infrastructure with Cloudflare DNS).

## Infrastructure providers

| Provider | Used for | Status |
|----------|----------|--------|
| [Proxmox](proxmox.md) | Tooling Cluster, Switch (Talos VMs) | Supported |
| AWS (EKS) | Tooling Cluster, Switch | Planned |

## DNS providers

| Provider | Setup | Credential env var |
|----------|-------|---------------------|
| [DigitalOcean](dns-digitalocean.md) | API token + zone delegation | `DIGITALOCEAN_TOKEN` |
| [Cloudflare](dns-cloudflare.md) | Scoped API token | `CLOUDFLARE_API_TOKEN` |
| [AWS Route53](dns-aws.md) | Hosted zone + IAM scope | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
