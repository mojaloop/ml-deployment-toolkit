output "cluster_name" {
  description = "kind cluster name"
  value       = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "Path to the written kubeconfig artifact"
  value       = local_sensitive_file.kubeconfig.filename
}

output "api_endpoint" {
  description = "API server endpoint as the host reaches it"
  value       = kind_cluster.this.endpoint
}
