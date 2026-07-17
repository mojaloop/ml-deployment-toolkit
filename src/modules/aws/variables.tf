# Variables for AWS EKS Cluster Module

variable "cluster" {
  description = "Cluster configuration (name, flux)"
  type        = any
}

variable "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  type        = string
}

variable "node_groups" {
  description = "Node group definitions from deployment template"
  type = list(object({
    name           = string
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    tags           = optional(list(string), [])
  }))
}

variable "artifacts_path" {
  description = "Path to artifacts directory"
  type        = string
}

variable "provider_config_path" {
  description = "Path to AWS provider config.yaml"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}
