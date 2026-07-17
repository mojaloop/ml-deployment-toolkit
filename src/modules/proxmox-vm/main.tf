# Proxmox Infrastructure Module
# Handles Talos VM provisioning on Proxmox Virtual Environment

locals {
  # Read Proxmox provider configuration from YAML
  provider_config = yamldecode(file(var.provider_config_path))

  # Process instances with storage config
  instances_with_specs = [
    for instance in var.instances : merge(instance, {
      storage_config = [
        for storage_item in instance.storage : {
          size      = storage_item.size
          interface = storage_item.interface
          storage_pool = try(storage_item.storage_pool,
          var.storage_override.disks != "" ? var.storage_override.disks : local.provider_config.storage.default_pool)
        }
      ]
    })
  ]

  # Extract node information (placement_group → Proxmox node name)
  nodes_map = {
    for instance in local.instances_with_specs :
    instance.name => instance.resolved_placement.placement_group
  }

  # Map instances by name for easy lookup
  instances_by_name = {
    for inst in local.instances_with_specs :
    inst.name => inst
  }
}

# Create VMs on Proxmox Virtual Environment
resource "proxmox_virtual_environment_vm" "instance" {
  for_each = { for inst in local.instances_with_specs : inst.name => inst }

  name      = each.value.name
  node_name = local.nodes_map[each.value.name]

  cpu {
    type    = local.provider_config.vm_defaults.cpu_type
    cores   = each.value.cores
    sockets = each.value.sockets
  }

  memory {
    dedicated = each.value.memory
  }

  scsi_hardware = local.provider_config.vm_defaults.scsihw

  boot_order = [local.provider_config.vm_defaults.boot_order]

  agent {
    enabled = local.provider_config.vm_defaults.qemu_agent
  }

  # Data disks - first disk (index 0) is the boot disk from downloaded OS image
  dynamic "disk" {
    for_each = each.value.storage_config
    content {
      datastore_id = disk.value.storage_pool
      file_id      = disk.key == 0 ? local.instance_image_ids[each.value.name] : null
      interface    = disk.value.interface
      size         = disk.value.size
      discard      = local.provider_config.vm_defaults.disk.discard ? "on" : "ignore"
      file_format  = local.provider_config.vm_defaults.disk.format
    }
  }

  # Cloud-init disk
  disk {
    datastore_id = each.value.storage_config[0].storage_pool
    interface    = "ide2"
    file_format  = "raw"
  }

  # Network device
  network_device {
    bridge   = var.network_bridge_override != "" ? var.network_bridge_override : local.provider_config.vm_defaults.network.bridge
    model    = local.provider_config.vm_defaults.network.model
    firewall = local.provider_config.vm_defaults.network.firewall
  }

  operating_system {
    type = "l26"
  }

  # Cloud-init configuration for Talos VMs
  initialization {
    user_data_file_id = local.talos_config_file_ids[each.key]
    meta_data_file_id = local.talos_meta_file_ids[each.key]
  }

  tags = each.value.tags

  on_boot         = true
  stop_on_destroy = true
  timeout_stop_vm = 60

  lifecycle {
    ignore_changes = [
      disk,
      initialization,
    ]
  }

  depends_on = [
    proxmox_virtual_environment_file.talos_config,
    proxmox_virtual_environment_file.talos_meta
  ]
}
