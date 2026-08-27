# Proxmox Cluster Composite Module
# Orchestrates: talos-gen-config -> proxmox-vm -> talos-bootstrap

locals {
  vip_address = var.cluster.vip

  # Read provider config for patch references
  provider_config = yamldecode(file(var.provider_config_path)).infra

  # All instances are Talos (no standalone support)
  talos_instances = var.instances

  # Get unique workload classes used
  used_workload_classes = toset([
    for inst in local.talos_instances :
    inst.workload_class
  ])

  # Per-class Talos fragments from the provider package's materialization
  # seat (providers/proxmox/classes.yaml), applied in declared order. *.tpl
  # fragments are templates over the provider facts (VIP, interface) — the
  # control-plane/mixed-plane VIP fragment is DECLARED per class there, not
  # special-cased here (the old "also apply control-plane provider patches
  # to mixed-plane" hardcode is gone).
  workload_class_patches = {
    for wc in local.used_workload_classes :
    wc => [
      for patch_name in try(var.provider_classes[wc].talos_fragments, []) :
      endswith(patch_name, ".tpl")
      ? templatefile("${var.patches_path}/${patch_name}", {
        interface   = "eth0"
        vip_address = local.vip_address
      })
      : file("${var.patches_path}/${patch_name}")
    ]
  }

  # Registry mirror patch (applied to all instances when proxy is active)
  registry_mirror_patch = var.oci_proxy_active ? [
    templatefile("${var.patches_path}/patch-registry-mirror.yaml.tpl", {
      proxy_url      = var.oci_proxy_url
      proxy_username = var.oci_proxy_username
      proxy_password = var.oci_proxy_password
    })
  ] : []

  # Nameserver patch (applied to all instances when nameservers configured)
  nameservers_patch = length(var.nameservers) > 0 ? [
    templatefile("${var.patches_path}/patch-nameservers.yaml.tpl", {
      nameservers = var.nameservers
    })
  ] : []

  # NTP patch (applied to all instances when ntp_servers configured)
  ntp_patch = length(var.ntp_servers) > 0 ? [
    templatefile("${var.patches_path}/patch-ntp.yaml.tpl", {
      ntp_servers = var.ntp_servers
    })
  ] : []
}

# Generate Talos configurations
module "talos_config" {
  source = "../talos-gen-config"

  cluster_name       = var.cluster.name
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  lb_ip              = local.vip_address

  talos_endpoints = [local.vip_address]

  artifacts_folder = var.artifacts_path

  # Generate per-instance configs with workload + provider + label/taint patches
  generate_per_instance = true
  instances = [
    for inst in local.talos_instances : {
      name           = inst.name
      workload_class = inst.workload_class
      talos_type     = var.workload_classes[inst.workload_class].talos_type
      workload_patches = concat(
        lookup(local.workload_class_patches, inst.workload_class, []),
        # Pool-keyed: the label derives from the pool name and the taints come
        # from the pool's own placement.yaml declaration.
        try([var.label_taint_patches[inst.group]], []),
        local.registry_mirror_patch,
        local.nameservers_patch,
        local.ntp_patch,
        # Per-pool fragments last so template/environment talos/<pool>.yaml
        # overlays win over the generic class patches (Talos merges in order).
        lookup(var.extra_pool_patches, try(inst.group, ""), []),
      )
    }
  ]
}

# Create VMs using proxmox-vm module
module "infrastructure" {
  source = "../vm"

  instances             = var.instances
  provider_config_path  = var.provider_config_path
  talos_image           = var.talos_image
  provider_image_config = local.provider_config.talos.image

  talos_configs = module.talos_config.instance_configs

  network_bridge_override = var.network_bridge_override
  storage_override        = var.storage_override

  depends_on = [module.talos_config]
}

# Apply Talos configuration to running nodes via Talos API
# First apply: no-op (config already delivered via cloud-init)
# Subsequent applies: pushes config changes without VM rebuild
resource "talos_machine_configuration_apply" "instance" {
  for_each = module.talos_config.instance_config_paths

  client_configuration        = module.talos_config.client_configuration
  machine_configuration_input = module.talos_config.instance_configs[each.key]
  node                        = module.infrastructure.instance_ips[each.key]
  endpoint                    = module.infrastructure.instance_ips[each.key]

  depends_on = [module.infrastructure]
}

# Bootstrap Talos Kubernetes cluster
module "bootstrap" {
  source = "../talos-bootstrap"

  control_plane_endpoints    = module.infrastructure.control_plane_ips
  worker_endpoints           = module.infrastructure.worker_ips
  talos_client_configuration = module.talos_config.client_configuration

  cluster_name     = var.cluster.name
  artifacts_folder = var.artifacts_path

  depends_on = [talos_machine_configuration_apply.instance]
}
