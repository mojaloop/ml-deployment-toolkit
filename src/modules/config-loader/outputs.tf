# Outputs from Config Loader Module

output "config" {
  description = "Complete deployer configuration (config.yaml)"
  value       = local.config
}

output "provider_name" {
  description = "Infrastructure provider name"
  value       = local.provider_name
}

output "instances" {
  description = "List of all instances with resolved placement"
  value       = local.instances
}

output "control_plane_instances" {
  description = "List of control plane instances (includes mixed-plane)"
  value       = local.control_plane_instances
}

output "worker_instances" {
  description = "List of worker instances"
  value       = local.worker_instances
}

output "workload_classes" {
  description = "Workload classes configuration"
  value       = local.workload_classes.classes
}

output "talos_version" {
  description = "Talos version (from workload-classes.yaml)"
  value       = local.talos_version
}

output "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  value       = local.kubernetes_version
}

output "talos_image" {
  description = "Talos image URL and file name (constructed from workload-classes.yaml)"
  value = {
    url       = local.talos_image_url
    file_name = local.talos_image_file_name
  }
}

output "label_taint_patches" {
  description = "Dynamic label/taint patches per workload class"
  value       = local.label_taint_patches
}

output "deployment_template" {
  description = "Infrastructure topology from profile (provider-specific structure)"
  value       = local.deployment_template
}

output "profile_app" {
  description = "Application scaling variables from profile"
  value       = try(local.profile.app, {})
}

output "profile_data" {
  description = "Data layer tuning variables from profile"
  value       = try(local.profile.data, {})
}

output "profile_cc" {
  description = "CC services scaling variables from profile"
  value       = try(local.profile.cc, {})
}

output "cluster" {
  description = "Cluster configuration"
  value       = local.config.cluster
}

output "dns" {
  description = "DNS configuration"
  value       = local.config.dns
}

output "app" {
  description = "Application configuration"
  value       = local.config.app
}

output "paths" {
  description = "Standard paths for shared resources"
  value = {
    patches = "../config/patches/talos"
  }
}
