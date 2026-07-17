output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubeconfig_content" {
  description = "Raw kubeconfig content (sensitive)"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://${var.control_plane_endpoints[0]}:6443"
}

output "bootstrap_complete" {
  description = "Flag indicating bootstrap is complete and cluster is healthy"
  value       = data.talos_cluster_health.this.id != null
  depends_on  = [data.talos_cluster_health.this]
}

output "bootstrap_node" {
  description = "The node that was used for bootstrap"
  value       = var.control_plane_endpoints[0]
}

output "cluster_healthy" {
  description = "Flag indicating the cluster health check has passed"
  value       = data.talos_cluster_health.this.id != null
}
