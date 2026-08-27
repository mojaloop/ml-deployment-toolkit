# OS Image Downloads for Proxmox
# Downloads Talos OS image based on constructed URL from config-loader

locals {
  # Get unique Proxmox nodes from instances
  unique_nodes = toset([
    for instance in local.instances_with_specs :
    instance.resolved_placement.placement_group
  ])

  # Single image for all instances (same Talos version)
  talos_image = {
    url           = var.talos_image.url
    file_name     = var.talos_image.file_name
    content_type  = var.provider_image_config.content_type
    datastore     = var.provider_image_config.datastore
    decompression = var.provider_image_config.decompression
  }

  # Create a flat map of node+image combinations that need to be downloaded
  node_image_downloads_map = {
    for node in local.unique_nodes :
    node => {
      node          = node
      url           = local.talos_image.url
      content_type  = local.talos_image.content_type
      datastore     = local.talos_image.datastore
      file_name     = local.talos_image.file_name
      decompression = local.talos_image.decompression
    }
  }
}

# Download OS image to each unique node
resource "proxmox_download_file" "os_image" {
  for_each = local.node_image_downloads_map

  content_type = each.value.content_type
  datastore_id = var.storage_override.images != "" ? var.storage_override.images : each.value.datastore
  node_name    = each.value.node

  url                     = each.value.url
  file_name               = each.value.file_name
  decompression_algorithm = each.value.decompression
  overwrite               = false
  overwrite_unmanaged     = true

  lifecycle {
    ignore_changes = [
      url,
      checksum,
      checksum_algorithm
    ]
  }
}

# Map instance name -> downloaded image ID for VM creation
locals {
  instance_image_ids = {
    for inst in local.instances_with_specs :
    inst.name => proxmox_download_file.os_image[
      local.nodes_map[inst.name]
    ].id
  }
}
