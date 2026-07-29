# Variables for Config Loader Module

variable "config_path" {
  description = "Path to the environment configuration file (environments/<env>/config.yaml)"
  type        = string
}

variable "workload_classes_path" {
  description = "Path to workload classes configuration"
  type        = string
}

variable "templates_path" {
  description = "Path to the deployment templates directory (config/templates)"
  type        = string
}

variable "env_name" {
  description = "Environment directory name — validated against cluster.name (empty skips the check)"
  type        = string
  default     = ""
}
