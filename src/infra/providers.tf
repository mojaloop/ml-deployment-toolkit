# Provider configurations (infra stack)

# Proxmox Provider — reads credentials from environment variables:
# PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_SSH_USERNAME, PROXMOX_VE_SSH_PASSWORD
provider "proxmox" {
  insecure = true

  ssh {
    agent = false
  }
}

# DigitalOcean Provider — reads token from DIGITALOCEAN_TOKEN env var
provider "digitalocean" {}

# AWS Provider — reads region from config, credentials from env
provider "aws" {
  region                      = try(local.config_raw.infra.aws.region, "us-east-1")
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

# Kubeconfig path — references the infra module's kubeconfig file resource
# (local.kubeconfig_path = local_sensitive_file filename). The value is a
# plan-time-known string, but the reference creates the graph dependency that
# makes Terraform configure these providers only AFTER the kubeconfig is
# written/rewritten during apply (stale endpoint on rebuilds otherwise).
# `make init` seeds a placeholder file on fresh deploys; its content is never
# dialed because the real kubeconfig replaces it before providers configure.
locals {
  static_kubeconfig = "../../artifacts/${var.env_name}/kubernetes/kubeconfig"
  kubeconfig        = local.kubeconfig_path != null ? local.kubeconfig_path : local.static_kubeconfig
}

provider "kubernetes" {
  config_path = local.kubeconfig
}

# Helm Provider — for Flux operator installation
provider "helm" {
  kubernetes {
    config_path = local.kubeconfig
  }
}

# Kubectl Provider — for the FluxInstance CR
provider "kubectl" {
  config_path = local.kubeconfig
}
