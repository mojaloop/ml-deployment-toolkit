output "flux_installed" {
  description = "Whether FluxCD controllers are installed"
  value       = helm_release.flux_operator.status == "deployed"
}

output "flux_namespace" {
  description = "Namespace where Flux is installed"
  value       = var.flux_namespace
}

output "flux_version" {
  description = "Installed Flux version"
  value       = var.flux_version
}
