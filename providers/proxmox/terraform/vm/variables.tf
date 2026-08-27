# Variables for Proxmox Infrastructure Module
# Talos-only (no standalone VM support)

variable "instances" {
  description = "List of Talos instances to create"
  type = list(object({
    name            = string
    cores           = number
    memory          = number
    sockets         = optional(number, 1)
    workload_class  = string
    storage         = list(any)
    tags            = list(string)
    placement_group = string
    resolved_placement = object({
      placement_group = string
    })
  }))
}

variable "provider_config_path" {
  description = "Path to Proxmox provider config.yaml"
  type        = string
}

variable "talos_configs" {
  description = "Map of instance name to Talos machine configuration YAML"
  type        = map(string)
  default     = {}
}

variable "vm_overrides" {
  description = "Per-instance resolved VM shape overrides (instance name -> {cpu_type?, balloon?, disk?{cache,iothread,ssd,discard,format}}) — the class/template/env chain already merged; keys absent here fall back to provider_config.vm_defaults"
  type        = any
  default     = {}
}

variable "talos_image" {
  description = "Talos image URL and file name (constructed by config-loader)"
  type = object({
    url       = string
    file_name = string
  })
}

variable "provider_image_config" {
  description = "Provider-specific image download settings"
  type = object({
    content_type  = string
    datastore     = string
    decompression = string
  })
}

variable "network_bridge_override" {
  description = "Override VM network bridge (empty = use provider config default)"
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
