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
    class          = string
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    # Availability zone this group is pinned to (from the environment's
    # placement.yaml pg -> AZ map). Empty = all cluster subnets, ASG spreads.
    az     = optional(string, "")
    labels = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    tags = optional(list(string), [])
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

variable "provider_classes" {
  description = "Per-class provider MATERIALIZATIONS from providers/aws/classes.yaml — node_config names a nodeadm NodeConfig fragment under the package's node-config/ directory, baked into the class's launch-template user data"
  type        = any
  default     = {}
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (infra.aws.api_allowed_cidrs)"
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0
    error_message = "infra.aws.api_allowed_cidrs must list at least one CIDR — the EKS API endpoint is never left open to the world implicitly."
  }
}

variable "cilium_version" {
  description = "Cilium chart version. Keep in lockstep with gitops/aws/cilium/helmrelease.yaml (and the Talos pins: Makefile CILIUM_VERSION, gitops/talos/cilium/helmrelease.yaml) — the Flux HelmRelease adopts this exact release."
  type        = string
  default     = "1.20.0"
}
