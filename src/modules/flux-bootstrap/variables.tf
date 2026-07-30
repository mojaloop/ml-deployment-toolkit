variable "flux_version" {
  description = "Flux distribution version (e.g. 2.7.2)"
  type        = string
  default     = "2.9.3"
}

variable "operator_version" {
  description = "Flux Operator Helm chart version"
  type        = string
  default     = "0.57.0"
}

variable "flux_namespace" {
  description = "Kubernetes namespace for Flux components"
  type        = string
  default     = "flux-system"
}
