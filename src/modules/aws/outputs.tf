# Outputs for AWS EKS Cluster Module

output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.this.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_name" {
  description = "Name of the cluster"
  value       = var.cluster.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.cluster.id
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubernetes_version" {
  description = "Actual Kubernetes version deployed"
  value       = aws_eks_cluster.this.version
}
