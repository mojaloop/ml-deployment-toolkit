# Environment name — selects config/environments/<env_name>/
variable "env_name" {
  description = "Environment name (maps to config/environments/<env_name>/)"
  type        = string
  default     = "cc"
}

# Sensitive variables injected via TF_VAR_* environment variables
# Used by flux-config module to create Kubernetes secrets

variable "dns_credentials" {
  description = "DNS provider credentials — provider-specific key-value pairs (e.g. digitalocean_token, cloudflare_api_token, aws_access_key_id)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "oci_repo_username" {
  description = "OCI repo registry username for Flux OCIRepository"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_repo_password" {
  description = "OCI repo registry password for Flux OCIRepository"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_username" {
  description = "OCI proxy (Harbor) username for container image pull-through cache"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_password" {
  description = "OCI proxy (Harbor) password for container image pull-through cache"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_user" {
  description = "MinIO root username for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_password" {
  description = "MinIO root password for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_admin_password" {
  description = "Harbor admin password for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password for observability stack"
  type        = string
  default     = ""
  sensitive   = true
}

# --- App Environment Data Layer Credentials ---

variable "mysql_root_password" {
  description = "MySQL root password for Percona XtraDB clusters"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_central_ledger_password" {
  description = "MySQL password for central_ledger user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_account_lookup_password" {
  description = "MySQL password for account_lookup user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_oracle_msisdn_password" {
  description = "MySQL password for oracle_msisdn user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mongodb_root_password" {
  description = "MongoDB admin password for Percona Server MongoDB"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mongodb_app_password" {
  description = "MongoDB mojaloop application user password"
  type        = string
  default     = ""
  sensitive   = true
}

# --- App Environment Auth Layer Credentials ---

variable "keycloak_db_password" {
  description = "Keycloak MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kratos_db_password" {
  description = "Kratos MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keto_db_password" {
  description = "Keto MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mcm_db_password" {
  description = "MCM MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "hydra_db_password" {
  description = "Hydra MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "hub_admin_password" {
  description = "Hub admin initial password (seeded into Kratos on first deploy)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "hub_admin_email" {
  description = "Hub admin email address (seeded into Kratos on first deploy)"
  type        = string
  default     = ""
}

variable "hubop_oidc_secret" {
  description = "Finance Portal OIDC client secret (hub-operators realm)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mcm_oidc_client_secret" {
  description = "MCM OIDC client secret (dfsps realm)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "role_assign_svc_secret" {
  description = "Role assignment service account secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dfsp_oidc_client_secret" {
  description = "DFSP OIDC client secret (dfsps realm, for Kratos DFSP login)"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Backup S3 Credentials (CC MinIO or cloud S3) ---

variable "backup_s3_access_key" {
  description = "S3 access key for backups"
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_secret_key" {
  description = "S3 secret key for backups"
  type        = string
  default     = ""
  sensitive   = true
}

# --- SMTP Credentials ---

variable "smtp_host" {
  description = "SMTP server hostname for Keycloak invitation emails"
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP server port"
  type        = string
  default     = "587"
}

variable "smtp_user" {
  description = "SMTP authentication username"
  type        = string
  default     = ""
}

variable "smtp_password" {
  description = "SMTP authentication password"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Alerting Delivery (Grafana contact points; dummy defaults keep
# provisioning valid — delivery silently fails until real values are set) ---

variable "alert_email_from" {
  description = "From address for Grafana alert emails"
  type        = string
  default     = "grafana@example.invalid"
}

variable "alert_email_to" {
  description = "Recipient address(es) for Grafana alert emails (comma-separated)"
  type        = string
  default     = "ops@example.invalid"
}

variable "telegram_bot_token" {
  description = "Telegram bot token for Grafana alerts (BotFather)"
  type        = string
  default     = "unset"
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "Telegram chat/group id for Grafana alerts"
  type        = string
  default     = "0"
}

# --- Hub Identity ---

variable "hub_participant_name" {
  description = "Hub participant name — single source of truth for HUB_PARTICIPANT.NAME (mojaloop chart), SWITCH_ID (MCM), and HUB_NAME (DFSP onboarding). Must match the string the switch uses as fspiop-source on outbound callbacks."
  type        = string
  default     = "Hub"
}

# --- DFSP Onboarding Parameters ---

variable "onboarding_funds_in" {
  description = "Initial deposit into DFSP settlement account"
  type        = string
  default     = "100000"
}

variable "onboarding_net_debit_cap" {
  description = "Maximum net debit position for DFSP participants"
  type        = string
  default     = "1000"
}


