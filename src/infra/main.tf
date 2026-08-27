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

  # Per-pool VM shape overrides: proxmox/<pool>.yaml in the selected template
  # directory (the shape), then in the environment (the instance) — the same
  # pool-keyed slot pattern as talos/<pool>.yaml. proxmox.yaml is the env-wide
  # provider sidecar, not a pool file. Resolution happens in the proxmox
  # package (vm_defaults -> class vm -> template pool -> env pool).
  template_vm_pool_overrides = {
    for f in try(fileset("${module.config.template_dir}/proxmox", "*.yaml"), []) :
    trimsuffix(f, ".yaml") => yamldecode(file("${module.config.template_dir}/proxmox/${f}"))
    if f != "proxmox.yaml"
  }
  env_vm_pool_overrides = {
    for f in try(fileset("${local.env_dir}/proxmox", "*.yaml"), []) :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.env_dir}/proxmox/${f}"))
    if f != "proxmox.yaml"
  }

  # Read raw config for provider selection (before module.config expands it)
  config_raw    = yamldecode(file(local.env_config_path))
  provider_name = local.config_raw.infra.provider
  # Bounded by the infra.provider schema enum (proxmox | aws | digitalocean).
  is_talos = local.provider_name == "proxmox"

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

# Binding names are validated, never silently no-op'd: a talos/<pool>.yaml
# fragment is matched via lookup by instance group, so a typo'd filename would
# otherwise never apply to any node — exactly what a renamed pool looks like
# after an upgrade. Template fragments must name a pool of the template itself;
# environment fragments must name a pool of the EFFECTIVE set (enabled: false
# drops a pool from it). check-bindings.sh enforces the same contract pre-plan.
resource "terraform_data" "binding_validation" {
  lifecycle {
    precondition {
      condition = alltrue([
        for k in keys(local.template_pool_patches) : contains(module.config.template_pool_names, k)
      ])
      error_message = "template talos/ fragment(s) name no pool of the selected template: ${join(", ", [for k in keys(local.template_pool_patches) : k if !contains(module.config.template_pool_names, k)])}. A fragment keyed on a nonexistent pool silently never applies. Template pools: ${join(", ", module.config.template_pool_names)}."
    }
    precondition {
      condition = alltrue([
        for k in keys(local.env_pool_patches) : contains(module.config.pool_names, k)
      ])
      error_message = "environment talos/ fragment(s) name no effective pool: ${join(", ", [for k in keys(local.env_pool_patches) : k if !contains(module.config.pool_names, k)])}. A fragment keyed on a nonexistent (or enabled: false) pool silently never applies. Effective pools: ${join(", ", module.config.pool_names)}."
    }
    precondition {
      condition = alltrue([
        for k in keys(local.template_vm_pool_overrides) : contains(module.config.template_pool_names, k)
      ])
      error_message = "template proxmox/ VM override(s) name no pool of the selected template: ${join(", ", [for k in keys(local.template_vm_pool_overrides) : k if !contains(module.config.template_pool_names, k)])}. Template pools: ${join(", ", module.config.template_pool_names)}."
    }
    precondition {
      condition = alltrue([
        for k in keys(local.env_vm_pool_overrides) : contains(module.config.pool_names, k)
      ])
      error_message = "environment proxmox/ VM override(s) name no effective pool: ${join(", ", [for k in keys(local.env_vm_pool_overrides) : k if !contains(module.config.pool_names, k)])}. Effective pools: ${join(", ", module.config.pool_names)}."
    }
  }
}

# Load and resolve configuration
module "config" {
  source = "../engine/config-loader"

  config_path           = local.env_config_path
  workload_classes_path = "../../config/definitions/workload-classes.yaml"
  providers_path        = "../../providers"
  env_name              = var.env_name
  env_dir               = local.env_dir
  dtk_tag               = var.dtk_tag
}

# Proxmox Cluster (Talos VMs)
module "proxmox" {
  count  = local.provider_name == "proxmox" ? 1 : 0
  source = "../../providers/proxmox/terraform/cluster"

  instances           = module.config.instances
  cluster             = module.config.cluster
  workload_classes    = module.config.workload_classes
  provider_classes    = module.config.provider_classes
  talos_version       = module.config.talos_version
  kubernetes_version  = module.config.kubernetes_version
  talos_image         = module.config.talos_image
  label_taint_patches = module.config.label_taint_patches

  patches_path         = "../../providers/proxmox/patches"
  artifacts_path       = local.artifacts_path
  provider_config_path = "../../providers/proxmox/params.yaml"
  extra_pool_patches   = local.extra_pool_patches

  # registry capability (image pull-through cache -> Talos machine mirrors)
  oci_proxy_active   = module.config.registry.active
  oci_proxy_url      = module.config.registry.url
  oci_proxy_username = lookup(var.secrets, "OCI_PROXY_USERNAME", "")
  oci_proxy_password = lookup(var.secrets, "OCI_PROXY_PASSWORD", "")

  # Per-pool VM shape overrides (template layer then environment layer);
  # resolved in the package against vm_defaults and the per-class vm seat.
  template_vm_pool_overrides = local.template_vm_pool_overrides
  env_vm_pool_overrides      = local.env_vm_pool_overrides

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
  source = "../../providers/digitalocean/terraform/cluster"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_pools         = module.config.do_node_pools

  artifacts_path       = local.artifacts_path
  provider_config_path = "../../providers/digitalocean/params.yaml"

  region = try(local.config_raw.infra.digitalocean.region, "nyc1")
}

# AWS Cluster (EKS Managed Kubernetes)
module "aws" {
  count  = local.provider_name == "aws" ? 1 : 0
  source = "../../providers/aws/terraform/cluster"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_groups        = module.config.aws_node_groups
  provider_classes   = module.config.provider_classes

  artifacts_path       = local.artifacts_path
  provider_config_path = "../../providers/aws/params.yaml"

  region            = try(local.config_raw.infra.aws.region, "us-east-1")
  api_allowed_cidrs = try(local.config_raw.infra.aws.api_allowed_cidrs, [])

  # The in-module Cilium install dials the cluster through the static
  # kubeconfig path — see the aliased provider's comment in providers.tf.
  providers = {
    helm = helm.bootstrap
  }
}

# AWS bootstrap — Gateway API CRDs and managed addons. Cilium itself is
# installed inside the aws module (between cluster and node groups — EKS
# only marks a node group ACTIVE once a CNI makes its nodes Ready). The
# Talos equivalent of all of this rides machine-config extraManifests.
module "aws_bootstrap" {
  count  = local.provider_name == "aws" ? 1 : 0
  source = "../../providers/aws/terraform/bootstrap"

  cluster_name       = module.aws[0].cluster_name
  kubernetes_version = module.aws[0].kubernetes_version

  depends_on = [module.aws]
}

# FluxCD Bootstrap — install controllers (always)
module "flux_bootstrap" {
  count  = local.provider_name != "" ? 1 : 0
  source = "../engine/flux-bootstrap"

  flux_version = module.config.flux_version

  depends_on = [
    module.proxmox,
    module.digitalocean,
    module.aws,
    module.aws_bootstrap
  ]
}
