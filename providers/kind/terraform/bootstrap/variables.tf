variable "gateway_api_crds_path" {
  description = "Gateway API CRD manifest to apply"
  type        = string
}

variable "cluster_generation" {
  description = "Changes when the cluster is rebuilt, replacing the applied manifests with it"
  type        = string
}
