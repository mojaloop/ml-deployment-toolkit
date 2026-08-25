# Variables for AWS Cluster Bootstrap Module

variable "cluster_name" {
  description = "EKS cluster name (addon attachment)"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API endpoint URL (https://...) — becomes Cilium's k8sServiceHost"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS cluster version (major.minor) for addon version resolution"
  type        = string
}

variable "cilium_version" {
  description = "Cilium chart version. Keep in lockstep with gitops/aws/cilium/helmrelease.yaml (and the Talos pins: Makefile CILIUM_VERSION, gitops/talos/cilium/helmrelease.yaml) — the Flux HelmRelease adopts this exact release."
  type        = string
  default     = "1.20.0"
}
