# Outputs for DigitalOcean DOKS Cluster Module

output "cluster_id" {
  description = "DOKS cluster ID"
  value       = digitalocean_kubernetes_cluster.this.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = digitalocean_kubernetes_cluster.this.endpoint
}

output "cluster_name" {
  description = "Name of the cluster"
  value       = var.cluster.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = digitalocean_vpc.cluster.id
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubernetes_version" {
  description = "Actual Kubernetes version deployed"
  value       = digitalocean_kubernetes_cluster.this.version
}
