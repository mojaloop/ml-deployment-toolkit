# Variables for Config Loader Module

variable "config_path" {
  description = "Path to the environment configuration file (environments/<env>/config.yaml)"
  type        = string
}

variable "workload_classes_path" {
  description = "Path to workload classes configuration"
  type        = string
}

variable "providers_path" {
  description = "Path to the provider packages root (providers/) — each package holds params.yaml, templates/<role>/<capacity>/, patches and its terraform modules"
  type        = string
}

variable "env_name" {
  description = "Environment directory name — validated against cluster.name (empty skips the check)"
  type        = string
  default     = ""
}

variable "env_dir" {
  description = "Environment directory (<environments_dir>/<env>) — holds the config.yaml siblings placement.yaml and proxmox/. Empty disables sidecar file loading."
  type        = string
  default     = ""
}

variable "dtk_tag" {
  description = "The clone's actual git tag (git describe --tags --exact-match), empty when untagged. When the environment declares dtk_version, a mismatch fails the plan — matched versions only."
  type        = string
  default     = ""
}
