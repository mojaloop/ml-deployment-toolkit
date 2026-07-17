# Outputs for Proxmox Cluster Composite Module

# Infrastructure outputs
output "vm_ips" {
  description = "IP addresses of all created VMs"
  value       = module.infrastructure.vm_ips
}

output "vm_ids" {
  description = "Proxmox VM IDs"
  value       = module.infrastructure.vm_ids
}

output "control_plane_ips" {
  description = "IP addresses of control plane nodes"
  value       = module.infrastructure.control_plane_ips
}

output "worker_ips" {
  description = "IP addresses of worker nodes"
  value       = module.infrastructure.worker_ips
}

output "instances" {
  description = "Created instances with their details"
  value       = module.infrastructure.instances
}

# Bootstrap outputs
output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = module.bootstrap.kubeconfig_path
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file"
  value       = module.talos_config.talosconfig_path
}

output "bootstrap_complete" {
  description = "Whether the bootstrap process is complete"
  value       = module.bootstrap.bootstrap_complete
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.bootstrap.cluster_endpoint
}

output "cluster_healthy" {
  description = "Whether the cluster is healthy"
  value       = module.bootstrap.cluster_healthy
}

output "talos_client_configuration" {
  description = "Talos client configuration (sensitive)"
  value       = module.talos_config.client_configuration
  sensitive   = true
}

output "cluster_name" {
  description = "Name of the Talos cluster"
  value       = var.cluster.name
}
