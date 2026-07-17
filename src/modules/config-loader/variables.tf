# Variables for Config Loader Module

variable "config_path" {
  description = "Path to the main configuration file (config/config.yaml)"
  type        = string
  default     = "../config/config.yaml"
}

variable "workload_classes_path" {
  description = "Path to workload classes configuration"
  type        = string
  default     = "../config/definitions/workload-classes.yaml"
}
