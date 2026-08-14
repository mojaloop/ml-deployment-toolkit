# Infra stack — provisions the cluster and installs Flux.
# Everything Flux-consumed (cluster-config, secrets, Kustomizations) lives in
# the config stack (src/config), which applies fast and cannot touch VMs.

locals {
  env_dir         = "${var.environments_dir}/${var.env_name}"
  env_config_path = "${local.env_dir}/config.yaml"
  artifacts_path  = "${var.artifacts_dir}/${var.env_name}"

  # Provider infra facts moved out of config.yaml into a sidecar the provider
  # alone consumes: <env>/proxmox/proxmox.yaml (network_bridge, storage pools).
  proxmox_env_file = "${local.env_dir}/proxmox/proxmox.yaml"
  proxmox_env      = fileexists(local.proxmox_env_file) ? yamldecode(file(local.proxmox_env_file)) : {}

  # Read raw config for provider selection (before module.config expands it)
  config_raw    = yamldecode(file(local.env_config_path))
  provider_name = local.config_raw.infra.provider
  is_talos      = contains(["proxmox", "openstack"], local.provider_name)

  config = module.config.config

  # Kubeconfig path — derived from provider module output (local_sensitive_file.filename).
  # This is an input attribute, so it's known at plan time even for new resources,
  # while the reference defers provider configuration until the file is written.
  # IMPORTANT: access the kubeconfig_path output directly, NOT via a provider
  # output object containing plan-unknown attributes (breaks kubectl provider
  # configuration at plan time).
  kubeconfig_paths = {
    proxmox      = length(module.proxmox) > 0 ? module.proxmox[0].kubeconfig_path : null
    digitalocean = length(module.digitalocean) > 0 ? module.digitalocean[0].kubeconfig_path : null
    aws          = length(module.aws) > 0 ? module.aws[0].kubeconfig_path : null
  }
  kubeconfig_path = try(local.kubeconfig_paths[local.provider_name], null)

  provider_outputs = {
    proxmox      = length(module.proxmox) > 0 ? module.proxmox[0] : null
    digitalocean = length(module.digitalocean) > 0 ? module.digitalocean[0] : null
    aws          = length(module.aws) > 0 ? module.aws[0] : null
  }
  active_provider = try(local.provider_outputs[local.provider_name], null)
}

# Load and resolve configuration
module "config" {
  source = "../modules/config-loader"

  config_path           = local.env_config_path
  workload_classes_path = "../../config/definitions/workload-classes.yaml"
  templates_path        = "../../config/templates"
  env_name              = var.env_name
  env_dir               = local.env_dir
  dtk_tag               = var.dtk_tag
}

# Proxmox Cluster (Talos VMs)
module "proxmox" {
  count  = local.provider_name == "proxmox" ? 1 : 0
  source = "../modules/proxmox"

  instances           = module.config.instances
  cluster             = module.config.cluster
  workload_classes    = module.config.workload_classes
  talos_version       = module.config.talos_version
  kubernetes_version  = module.config.kubernetes_version
  talos_image         = module.config.talos_image
  label_taint_patches = module.config.label_taint_patches

  patches_path         = module.config.paths.patches
  artifacts_path       = local.artifacts_path
  provider_config_path = "../../config/templates/proxmox/params.yaml"

  # registry capability (image pull-through cache -> Talos machine mirrors)
  oci_proxy_active   = module.config.registry.active
  oci_proxy_url      = module.config.registry.url
  oci_proxy_username = lookup(var.secrets, "OCI_PROXY_USERNAME", "")
  oci_proxy_password = lookup(var.secrets, "OCI_PROXY_PASSWORD", "")

  nameservers             = try(local.config_raw.infra.talos.nameservers, [])
  ntp_servers             = try(local.config_raw.infra.talos.ntp_servers, [])
  network_bridge_override = try(local.proxmox_env.network_bridge, "")
  storage_override = {
    disks    = try(local.proxmox_env.storage.disks, "")
    images   = try(local.proxmox_env.storage.images, "")
    snippets = try(local.proxmox_env.storage.snippets, "")
  }
}

# DigitalOcean Cluster (DOKS Managed Kubernetes)
module "digitalocean" {
  count  = local.provider_name == "digitalocean" ? 1 : 0
  source = "../modules/digitalocean"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_pools         = module.config.do_node_pools

  artifacts_path       = local.artifacts_path
  provider_config_path = "../../config/templates/digitalocean/params.yaml"

  region = try(local.config_raw.infra.digitalocean.region, "nyc1")
}

# AWS Cluster (EKS Managed Kubernetes)
module "aws" {
  count  = local.provider_name == "aws" ? 1 : 0
  source = "../modules/aws"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_groups        = module.config.aws_node_groups

  artifacts_path       = local.artifacts_path
  provider_config_path = "../../config/templates/aws/params.yaml"

  region = try(local.config_raw.infra.aws.region, "us-east-1")
}

# FluxCD Bootstrap — install controllers (always)
module "flux_bootstrap" {
  count  = local.provider_name != "" ? 1 : 0
  source = "../modules/flux-bootstrap"

  flux_version = module.config.flux_version

  depends_on = [
    module.proxmox,
    module.digitalocean,
    module.aws
  ]
}
