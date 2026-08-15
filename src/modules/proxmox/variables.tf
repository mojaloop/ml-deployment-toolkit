# Variables for Proxmox Cluster Composite Module

variable "instances" {
  description = "List of instances to create (from config-loader)"
  type        = any
}

variable "extra_pool_patches" {
  description = "Per-pool Talos machine-config fragments (pool name -> ordered list of rendered patch documents): template-layer talos/<pool>.yaml first, environment-layer second. Applied to every node of the matching pool."
  type        = map(list(string))
  default     = {}
}

variable "cluster" {
  description = "Cluster configuration (name, vip, flux)"
  type        = any
}

variable "workload_classes" {
  description = "Workload classes configuration"
  type        = any
  default     = {}
}

variable "talos_version" {
  description = "Talos version (from workload-classes.yaml)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  type        = string
}

variable "talos_image" {
  description = "Talos image URL and file name (constructed by config-loader)"
  type = object({
    url       = string
    file_name = string
  })
}

variable "label_taint_patches" {
  description = "Dynamic label/taint patches per POOL (node group name): mechanically derived node label plus the pool's declared taints"
  type        = map(string)
  default     = {}
}

variable "patches_path" {
  description = "Path to Talos patches directory"
  type        = string
}

variable "artifacts_path" {
  description = "Path to artifacts directory"
  type        = string
}

variable "provider_config_path" {
  description = "Path to Proxmox provider config.yaml"
  type        = string
}

variable "oci_proxy_active" {
  description = "Enable container image proxy through Harbor"
  type        = bool
  default     = false
}

variable "oci_proxy_url" {
  description = "Harbor proxy cache URL (no protocol prefix)"
  type        = string
  default     = ""
}

variable "oci_proxy_username" {
  description = "Harbor proxy cache username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_password" {
  description = "Harbor proxy cache password"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Talos node OS overrides ---

variable "nameservers" {
  description = "DNS nameservers for Talos nodes (optional — omit for DHCP default)"
  type        = list(string)
  default     = []
}

variable "ntp_servers" {
  description = "NTP servers for Talos nodes (optional — omit for Talos default)"
  type        = list(string)
  default     = []
}

# --- Proxmox hypervisor overrides ---

variable "network_bridge_override" {
  description = "Override Proxmox VM network bridge (empty = use provider config default)"
  type        = string
  default     = ""
}

variable "storage_override" {
  description = "Override Proxmox storage locations (empty values = use provider config defaults)"
  type = object({
    disks    = string
    images   = string
    snippets = string
  })
  default = {
    disks    = ""
    images   = ""
    snippets = ""
  }
}
