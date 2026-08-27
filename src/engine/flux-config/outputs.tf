# Outputs from the Flux Config module

output "config_map_name" {
  description = "Name of the cluster-config ConfigMap"
  value       = kubernetes_config_map_v1.cluster_config.metadata[0].name
}

output "secrets_name" {
  description = "Name of the cluster-secrets Secret"
  value       = kubernetes_secret_v1.cluster_secrets.metadata[0].name
}

output "kustomization_names" {
  description = "Names of the created Flux Kustomizations"
  value       = keys(local.kustomizations)
}

output "generated_secrets" {
  description = "Generated internal service passwords (retrieve via 'make secrets')"
  value       = local.generated_secrets
  sensitive   = true
}
