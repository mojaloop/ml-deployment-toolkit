variable "flux_version" {
  description = "Flux distribution version — single-sourced from config/definitions/workload-classes.yaml via config-loader; no default here so the platform definition is the only source."
  type        = string
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
