# Output Values for Talos Configuration

output "cluster_name" {
  description = "The name of the Talos cluster"
  value       = local.cluster_name
}

output "cluster_endpoint" {
  description = "The API endpoint of the Talos cluster"
  value       = local.cluster_endpoint
}

output "kubernetes_version" {
  description = "The Kubernetes version configured"
  value       = local.kubernetes_version
}

output "talos_version" {
  description = "The Talos version configured"
  value       = local.talos_version
}

output "machine_secrets" {
  description = "The generated machine secrets (sensitive)"
  value       = talos_machine_secrets.this.machine_secrets
  sensitive   = true
}

output "client_configuration" {
  description = "The client configuration for talosctl (sensitive)"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "talos_secrets_path" {
  description = "Path to the generated Talos secrets file"
  value       = local_sensitive_file.machine_secrets.filename
}

output "talosconfig_path" {
  description = "Path to the talosconfig file for talosctl"
  value       = local_file.talosconfig.filename
}

output "instance_configs" {
  description = "Per-instance machine configurations (sensitive)"
  value = {
    for name, config in data.talos_machine_configuration.instance :
    name => config.machine_configuration
  }
  sensitive = true
}

output "instance_config_paths" {
  description = "Paths to per-instance configuration files"
  value = {
    for name, file in local_file.instance_config :
    name => file.filename
  }
}
