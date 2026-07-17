# Variables for DigitalOcean DOKS Cluster Module

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
    name  = string
    size  = string
    count = number
    tags  = optional(list(string), [])
  }))
}

variable "artifacts_path" {
  description = "Path to artifacts directory"
  type        = string
}

variable "provider_config_path" {
  description = "Path to DigitalOcean provider config.yaml"
  type        = string
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
}

