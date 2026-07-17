# Config Loader Module
# Loads and processes YAML configuration files

locals {
  # Load main deployer configuration
  config = yamldecode(file(var.config_path))

  # Load workload classes (single source of truth for versions)
  workload_classes = yamldecode(file(var.workload_classes_path))

  # Kubernetes version — used by all providers
  kubernetes_version = local.workload_classes.kubernetes_version

  # Talos version — only relevant for on-prem (Proxmox)
  talos_version = local.workload_classes.talos_version

  # Extract provider name and placement map
  provider_name = local.config.infra.provider
  placement_map = try(local.config.infra[local.provider_name].placement, {})

  # Load provider config
  provider_config = yamldecode(file("../config/providers/${local.provider_name}/config.yaml"))

  # Talos image URL — only constructed for on-prem providers that define talos.platform
  talos_image_platform  = try(local.provider_config.talos.platform, "")
  talos_image_schematic = try(local.workload_classes.talos_image.schematic, "")
  talos_image_arch      = try(local.workload_classes.talos_image.arch, "amd64")
  talos_image_url = local.talos_image_platform != "" ? (
    "https://factory.talos.dev/image/${local.talos_image_schematic}/${local.talos_version}/${local.talos_image_platform}-${local.talos_image_arch}.raw.gz"
  ) : ""
  talos_image_file_name = local.talos_image_platform != "" ? (
    "talos-${local.talos_version}-${local.talos_image_arch}.img"
  ) : ""

  # Load sizing profile (infra + app + data tuning, per provider/role)
  profile             = yamldecode(file("../config/providers/${local.provider_name}/profiles/${local.config.cluster.role}/${local.config.profile}.yaml"))
  deployment_template = local.profile.infra

  # Process instances — only for on-prem templates that define them
  instances = try([
    for instance in local.deployment_template.instances : merge(instance, {
      name = "${local.config.cluster.name}-${instance.name}"
      tags = concat(try(instance.tags, []), [local.config.cluster.name])
      resolved_placement = {
        placement_group = try(
          lookup(local.placement_map, instance.placement_group, instance.placement_group),
          ""
        )
      }
    })
  ], [])

  # Separate by workload class (mixed-plane counts as control-plane for bootstrap/VIP)
  control_plane_instances = [
    for instance in local.instances :
    instance if contains(["control-plane", "mixed-plane"], instance.workload_class)
  ]

  worker_instances = [
    for instance in local.instances :
    instance if startswith(instance.workload_class, "worker")
  ]

  # Dynamic label/taint patches per workload class (Talos only)
  label_taint_patches = {
    for class_name, class_def in local.workload_classes.classes :
    class_name => yamlencode({
      machine = merge(
        length(try(class_def.node_labels, {})) > 0 ? { nodeLabels = class_def.node_labels } : {},
        length(try(class_def.node_taints, [])) > 0 ? {
          nodeTaints = {
            for taint in class_def.node_taints :
            "${taint.key}=${taint.value}" => taint.effect
          }
        } : {}
      )
    })
    if length(try(class_def.node_labels, {})) > 0 || length(try(class_def.node_taints, [])) > 0
  }
}
