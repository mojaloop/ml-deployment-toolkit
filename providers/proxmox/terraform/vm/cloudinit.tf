# Cloud-Init Configuration for Talos VMs
# Uploads Talos machine configs and meta-data as Proxmox snippets

locals {
  # All instances are Talos (no standalone support in this module)
  talos_instances_map = {
    for inst in local.instances_with_specs :
    inst.name => inst
  }
}

# Upload Talos machine configurations
resource "proxmox_virtual_environment_file" "talos_config" {
  for_each = local.talos_instances_map

  content_type = "snippets"
  datastore_id = var.storage_override.snippets != "" ? var.storage_override.snippets : local.provider_config.talos.image.datastore
  node_name    = local.nodes_map[each.key]

  source_raw {
    data      = var.talos_configs[each.key]
    file_name = "${each.key}-talos-config.yaml"
  }
}

# Map of instance names to config file IDs
locals {
  talos_config_file_ids = {
    for name, config_resource in proxmox_virtual_environment_file.talos_config :
    name => config_resource.id
  }
}

# Generate cloud-init meta-data for Talos VMs (provides hostname to nocloud platform)
resource "proxmox_virtual_environment_file" "talos_meta" {
  for_each = local.talos_instances_map

  content_type = "snippets"
  datastore_id = var.storage_override.snippets != "" ? var.storage_override.snippets : local.provider_config.talos.image.datastore
  node_name    = local.nodes_map[each.key]

  source_raw {
    data      = <<-EOF
      instance-id: ${each.value.name}
      local-hostname: ${each.value.name}
    EOF
    file_name = "${each.key}-meta-data"
  }
}

# Map of instance names to meta-data file IDs
locals {
  talos_meta_file_ids = {
    for name, meta_resource in proxmox_virtual_environment_file.talos_meta :
    name => meta_resource.id
  }
}
