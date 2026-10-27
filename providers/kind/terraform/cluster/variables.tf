# Variables for kind Cluster Module

variable "cluster" {
  description = "Cluster configuration (name, flux)"
  type        = any
}

variable "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  type        = string
}

variable "node_pools" {
  description = "Node pool definitions from deployment template"
  type = list(object({
    name   = string
    count  = number
    role   = string
    labels = map(string)
    taints = optional(list(any), [])
  }))
}

variable "cilium_version" {
  description = "Cilium chart version for the bootstrap install"
  type        = string
}

variable "artifacts_path" {
  description = "Path to artifacts directory"
  type        = string
}

variable "provider_config_path" {
  description = "Path to the kind provider params.yaml"
  type        = string
}
