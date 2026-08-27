# Variables for AWS Cluster Bootstrap Module

variable "cluster_name" {
  description = "EKS cluster name (addon attachment)"
  type        = string
}


variable "kubernetes_version" {
  description = "EKS cluster version (major.minor) for addon version resolution"
  type        = string
}

