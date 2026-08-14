# Environment name — selects <environments_dir>/<env_name>/
variable "env_name" {
  description = "Environment name (maps to <environments_dir>/<env_name>/)"
  type        = string
}

# Adopter data lives outside the DTK clone, in sibling directories under the
# project root. Both paths are entry-point parameters so a non-standard layout
# stays possible; the defaults assume <project-root>/{ml-deployment-toolkit,
# environments,artifacts} and are relative to this stack directory.
variable "environments_dir" {
  description = "Directory holding environment directories (adopter-owned, outside the clone)"
  type        = string
  default     = "../../../environments"
}

variable "artifacts_dir" {
  description = "Directory holding generated per-environment artifacts and Terraform state (outside the clone)"
  type        = string
  default     = "../../../artifacts"
}

# External credentials from environments/<env>/.env, passed as one map by the
# Makefile (keys are the .env variable names). The infra stack only reads the
# registry-proxy credentials (Talos machine mirrors).
variable "secrets" {
  description = "External credentials map from .env (keys = env var names)"
  type        = map(string)
  default     = {}
  sensitive   = true
}
