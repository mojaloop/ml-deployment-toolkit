variable "control_plane_endpoints" {
  description = "List of control plane node IP addresses"
  type        = list(string)

  validation {
    condition     = length(var.control_plane_endpoints) > 0
    error_message = "At least one control plane endpoint is required for bootstrap."
  }
}

variable "worker_endpoints" {
  description = "List of worker node IP addresses (for health checks)"
  type        = list(string)
  default     = []
}

variable "talos_client_configuration" {
  description = "Talos client configuration from machine secrets"
  type = object({
    ca_certificate     = string
    client_certificate = string
    client_key         = string
  })
  sensitive = true
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "artifacts_folder" {
  description = "Path to artifacts folder where kubeconfig will be written. Always passed explicitly by callers; the default matches the sibling project layout relative to a stack root."
  type        = string
  default     = "../../../artifacts"
}
