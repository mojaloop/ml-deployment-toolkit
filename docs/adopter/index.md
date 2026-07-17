# Adopter Guide

[docs](../index.md) / Adopter Guide

**Audiences:** adopter (deploy)

This guide covers configuring, deploying, and managing ML Deployment Toolkit environments. You configure two files per environment (`config.yaml` and `.env`), run Terraform via Make, and get a Kubernetes cluster with FluxCD reconciling platform services.

You never fork or edit the platform bundle -- all personalization flows through your local configuration.

For architecture details and design rationale, see the [Architecture](../architecture/index.md) section. This guide focuses on how to deploy and manage.

## Contents

| Page | Description |
|------|-------------|
| [Prerequisites](prerequisites.md) | Required tools, provider accounts, credentials |
| [Provider setup](provider-setup/index.md) | How to provision provider accounts, tokens, and DNS zones |
| [Configuration](configuration.md) | Environment config, secrets, named environments, OCI settings |
| [Deployment](deployment.md) | Shared deployment workflow (init, plan/apply, commands, destroy) |
| [Deploy a Tooling Cluster (CC)](deployment-cc.md) | CC-specific config, verification, accessing services |
| [Deploy a Switch (SW)](deployment-sw.md) | SW-specific config, verification, Harbor proxy cache |
| [Upgrading](upgrading.md) | Upgrading platform services and infrastructure |
| [Known issues](known-issues.md) | Deployment-level known issues and workarounds |

## Quick start

1. **Clone the repository**

   ```bash
   git clone <repo-url> && cd ml-deployment-toolkit
   ```

2. **Create your environment configuration**

   Copy the sample environment and fill in your values. See [Configuration](configuration.md) for details on each section.

   ```bash
   cp config/environments/ml-cc/.env.sample config/environments/myenv/.env
   # Edit config/environments/myenv/config.yaml and .env
   ```

3. **Deploy**

   ```bash
   make init ENV=myenv
   make plan-apply ENV=myenv
   ```

4. **Publish the GitOps artifact** (if using OCI-based Flux)

   ```bash
   make push-gitops ENV=myenv
   ```

Each step is covered in depth in the pages linked above. Start with [Prerequisites](prerequisites.md) if this is your first deployment.
