# Talos Bootstrap Module
# Initializes the Talos Kubernetes cluster after infrastructure is provisioned

terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
  }
}

# Bootstrap the Talos cluster on the first control plane node
resource "talos_machine_bootstrap" "this" {
  client_configuration = var.talos_client_configuration
  endpoint             = var.control_plane_endpoints[0]
  node                 = var.control_plane_endpoints[0]
}

# Generate kubeconfig after successful bootstrap
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = var.talos_client_configuration
  endpoint             = var.control_plane_endpoints[0]
  node                 = var.control_plane_endpoints[0]

  depends_on = [talos_machine_bootstrap.this]
}

# Write kubeconfig to artifacts/kubernetes/ directory
resource "local_sensitive_file" "kubeconfig" {
  filename             = "${var.artifacts_folder}/kubernetes/kubeconfig"
  content              = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission      = "0600"
  directory_permission = "0700"
}

# Wait for cluster to be fully healthy
data "talos_cluster_health" "this" {
  client_configuration = var.talos_client_configuration

  control_plane_nodes = var.control_plane_endpoints
  worker_nodes        = var.worker_endpoints

  endpoints = var.control_plane_endpoints

  skip_kubernetes_checks = false

  timeouts = {
    read = "30m"
  }

  depends_on = [
    talos_machine_bootstrap.this,
    local_sensitive_file.kubeconfig
  ]
}
