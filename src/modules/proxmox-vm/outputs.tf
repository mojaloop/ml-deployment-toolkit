# Outputs for Proxmox Infrastructure Module

output "vm_ips" {
  description = "IP addresses of created VMs"
  value = {
    for name, vm in proxmox_virtual_environment_vm.instance :
    name => vm.ipv4_addresses[0][0] if length(vm.ipv4_addresses) > 0
  }
}

output "vm_ids" {
  description = "Proxmox VM IDs"
  value = {
    for name, vm in proxmox_virtual_environment_vm.instance :
    name => vm.vm_id
  }
}

output "instances" {
  description = "Created instances with their details"
  value = {
    for inst in local.instances_with_specs :
    inst.name => {
      name           = inst.name
      workload_class = inst.workload_class
      node           = local.nodes_map[inst.name]
      cores          = inst.cores
      memory         = inst.memory
      tags           = inst.tags
    }
  }
}

output "control_plane_ips" {
  description = "IP addresses of control plane nodes (for bootstrap)"
  value = [
    for inst in local.instances_with_specs :
    element(
      proxmox_virtual_environment_vm.instance[inst.name].ipv4_addresses[
        index(
          proxmox_virtual_environment_vm.instance[inst.name].network_interface_names,
          "eth0"
        )
      ],
      0
    )
    if contains(["control-plane", "mixed-plane"], inst.workload_class)
  ]
}

output "worker_ips" {
  description = "IP addresses of worker nodes (for bootstrap health checks)"
  value = [
    for inst in local.instances_with_specs :
    element(
      proxmox_virtual_environment_vm.instance[inst.name].ipv4_addresses[
        index(
          proxmox_virtual_environment_vm.instance[inst.name].network_interface_names,
          "eth0"
        )
      ],
      0
    )
    if startswith(inst.workload_class, "worker")
  ]
}

output "instance_ips" {
  description = "Map of instance name to eth0 IP address"
  value = {
    for inst in local.instances_with_specs :
    inst.name => element(
      proxmox_virtual_environment_vm.instance[inst.name].ipv4_addresses[
        index(
          proxmox_virtual_environment_vm.instance[inst.name].network_interface_names,
          "eth0"
        )
      ],
      0
    )
  }
}
