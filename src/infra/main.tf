# Infra stack — provisions the cluster and installs Flux.
# Everything Flux-consumed (cluster-config, secrets, Kustomizations) lives in
# the config stack (src/config), which applies fast and cannot touch VMs.

locals {
  env_dir         = "${var.environments_dir}/${var.env_name}"
  env_config_path = "${local.env_dir}/config.yaml"
  artifacts_path  = "${var.artifacts_dir}/${var.env_name}"

  # Provider infra facts moved out of config.yaml into sidecars the provider
  # alone consumes: <env>/proxmox/proxmox.yaml (network_bridge, storage pools)
  # and <env>/talos.yaml (node nameservers, NTP). The template layer may also
  # carry proxmox/proxmox.yaml defaults; resolution is env > template > params.
  # The condition sits INSIDE yamldecode so both branches are strings —
  # `fileexists(...) ? yamldecode(...) : {}` fails type unification the moment
  # the file exists (the decoded object type cannot unify with object({})).
  # NOT try(): a malformed sidecar must fail the plan loudly, never be
  # silently ignored.
  proxmox_env_file      = "${local.env_dir}/proxmox/proxmox.yaml"
  proxmox_env           = yamldecode(fileexists(local.proxmox_env_file) ? file(local.proxmox_env_file) : "{}")
  proxmox_template_file = "${module.config.template_dir}/proxmox/proxmox.yaml"
  proxmox_template      = yamldecode(fileexists(local.proxmox_template_file) ? file(local.proxmox_template_file) : "{}")
  talos_env_file        = "${local.env_dir}/talos.yaml"
  talos_env             = yamldecode(fileexists(local.talos_env_file) ? file(local.talos_env_file) : "{}")

  # Per-pool Talos machine-config fragments: talos/<pool>.yaml in the selected
  # template directory (the shape), then in the environment (the instance),
  # applied in that order. Terraform-substituted like every environment file;
  # an undefined token fails the plan.
  talos_fragment_vars = {
    CLUSTER_NAME = try(module.config.cluster.name, var.env_name)
    DOMAIN       = try(module.config.dns.domain, "")
  }
  template_talos_dir = "${module.config.template_dir}/talos"
  env_talos_dir      = "${local.env_dir}/talos"
  template_pool_patches = {
    for f in try(fileset(local.template_talos_dir, "*.yaml"), []) :
    trimsuffix(f, ".yaml") => templatefile("${local.template_talos_dir}/${f}", local.talos_fragment_vars)
  }
  env_pool_patches = {
    for f in try(fileset(local.env_talos_dir, "*.yaml"), []) :
    trimsuffix(f, ".yaml") => templatefile("${local.env_talos_dir}/${f}", local.talos_fragment_vars)
  }
  extra_pool_patches = {
    for pool in distinct(concat(keys(local.template_pool_patches), keys(local.env_pool_patches))) :
    pool => compact([
      lookup(local.template_pool_patches, pool, ""),
      lookup(local.env_pool_patches, pool, ""),
    ])
  }

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
  extra_pool_patches   = local.extra_pool_patches

  # registry capability (image pull-through cache -> Talos machine mirrors)
  oci_proxy_active   = module.config.registry.active
  oci_proxy_url      = module.config.registry.url
  oci_proxy_username = lookup(var.secrets, "OCI_PROXY_USERNAME", "")
  oci_proxy_password = lookup(var.secrets, "OCI_PROXY_PASSWORD", "")

  nameservers             = try(local.talos_env.nameservers, [])
  ntp_servers             = try(local.talos_env.ntp_servers, [])
  network_bridge_override = try(local.proxmox_env.network_bridge, try(local.proxmox_template.network_bridge, ""))
  storage_override = {
    disks    = try(local.proxmox_env.storage.disks, try(local.proxmox_template.storage.disks, ""))
    images   = try(local.proxmox_env.storage.images, try(local.proxmox_template.storage.images, ""))
    snippets = try(local.proxmox_env.storage.snippets, try(local.proxmox_template.storage.snippets, ""))
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
