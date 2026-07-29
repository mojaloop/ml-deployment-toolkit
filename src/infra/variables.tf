# Environment name — selects environments/<env_name>/
variable "env_name" {
  description = "Environment name (maps to environments/<env_name>/)"
  type        = string
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
