# Outputs from the infra stack

output "cluster_name" {
  description = "The name of the cluster"
  value       = module.config.cluster.name
}

output "cluster_endpoint" {
  description = "The API endpoint of the cluster"
  value = (
    local.is_talos ? try(module.config.cluster.vip, null)
    : local.active_provider != null ? try(local.active_provider.cluster_endpoint, null)
    : null
  )
  sensitive = true
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local.kubeconfig_path
  sensitive   = true
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file (Talos providers only)"
  value = (
    local.is_talos && local.active_provider != null
    ? try(local.active_provider.talosconfig_path, null)
    : null
  )
  sensitive = true
}

output "flux_installed" {
  description = "Whether FluxCD controllers are installed"
  value       = length(module.flux_bootstrap) > 0 ? module.flux_bootstrap[0].flux_installed : false
}
