# Outputs from the config stack

output "kustomization_names" {
  description = "Names of the created Flux Kustomizations"
  value       = length(module.flux_config) > 0 ? module.flux_config[0].kustomization_names : []
}

# Retrieve with: make secrets ENV=<env>
output "generated_secrets" {
  description = "Generated internal service passwords"
  value       = length(module.flux_config) > 0 ? module.flux_config[0].generated_secrets : {}
  sensitive   = true
}
