output "config_map_name" {
  description = "Name of the cluster-config ConfigMap"
  value       = kubernetes_config_map_v1.cluster_config.metadata[0].name
}

output "secrets_name" {
  description = "Name of the cluster-secrets Secret"
  value       = kubernetes_secret_v1.cluster_secrets.metadata[0].name
}

output "oci_repository_created" {
  description = "Whether the OCIRepository was created"
  value       = true
}

output "kustomization_created" {
  description = "Whether the Kustomization was created"
  value       = true
}
