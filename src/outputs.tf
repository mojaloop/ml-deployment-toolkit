# Output values from the root configuration

output "cluster_name" {
  description = "The name of the cluster"
  value       = local.config.cluster.name
}

output "cluster_endpoint" {
  description = "The API endpoint of the cluster"
  value = (
    local.is_talos ? try(local.config.cluster.vip, null)
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

output "oci_repo_active" {
  description = "Whether Flux OCI reconciliation is active"
  value       = local.oci_active
}
