# DigitalOcean Cluster Composite Module
# Provisions DOKS managed Kubernetes cluster

locals {
  provider_config = yamldecode(file(var.provider_config_path))
}

# VPC for cluster network isolation
resource "digitalocean_vpc" "cluster" {
  name     = "${var.cluster.name}-vpc"
  region   = var.region
  ip_range = try(local.provider_config.vpc.ip_range, "10.10.0.0/16")
}

# Resolve Kubernetes version to DO-specific version string (e.g. "1.34.0-do.0")
data "digitalocean_kubernetes_versions" "this" {
  version_prefix = "${var.kubernetes_version}."
}

# DOKS Managed Kubernetes Cluster
resource "digitalocean_kubernetes_cluster" "this" {
  name    = var.cluster.name
  region  = var.region
  version = data.digitalocean_kubernetes_versions.this.latest_version

  vpc_uuid = digitalocean_vpc.cluster.id

  # First node pool is required inline
  node_pool {
    name       = var.node_pools[0].name
    size       = var.node_pools[0].size
    node_count = var.node_pools[0].count
    tags       = try(var.node_pools[0].tags, [])
  }
}

# Additional node pools (if any beyond the first)
resource "digitalocean_kubernetes_node_pool" "extra" {
  for_each = {
    for i, pool in var.node_pools : pool.name => pool
    if i > 0
  }

  cluster_id = digitalocean_kubernetes_cluster.this.id
  name       = each.value.name
  size       = each.value.size
  node_count = each.value.count
  tags       = try(each.value.tags, [])
}

# Write kubeconfig to artifacts
resource "local_sensitive_file" "kubeconfig" {
  filename             = "${var.artifacts_path}/kubernetes/kubeconfig"
  content              = digitalocean_kubernetes_cluster.this.kube_config[0].raw_config
  file_permission      = "0600"
  directory_permission = "0700"
}
