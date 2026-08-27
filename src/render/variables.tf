variable "env_name" {
  description = "Environment directory name under environments_dir"
  type        = string
}

variable "environments_dir" {
  description = "Absolute path to the environments root (sibling of the clone)"
  type        = string
}

variable "dtk_tag" {
  description = "The clone's exact git tag (empty when untagged) — forwarded to config-loader's dtk_version assert so a render on a mismatched clone fails like a plan would"
  type        = string
  default     = ""
}
