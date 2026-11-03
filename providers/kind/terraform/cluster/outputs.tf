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

output "cluster_generation" {
  description = "Changes when the cluster is rebuilt, so downstream in-cluster resources follow it"
  value       = sha1(kind_cluster.this.kubeconfig)
}
