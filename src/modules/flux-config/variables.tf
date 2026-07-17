variable "flux_namespace" {
  description = "Kubernetes namespace for Flux resources"
  type        = string
  default     = "flux-system"
}

variable "cluster_name" {
  description = "Cluster name for config"
  type        = string
}

variable "cluster_role" {
  description = "Cluster role — determines which gitops paths are deployed (base, cc, or env)"
  type        = string

  validation {
    condition     = contains(["base", "cc", "env"], var.cluster_role)
    error_message = "cluster_role must be 'base', 'cc', or 'env'."
  }
}

variable "cluster_vip" {
  description = "Cluster VIP address (on-prem) or endpoint (cloud)"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Domain name"
  type        = string
}

variable "dns_provider" {
  description = "DNS provider name"
  type        = string
}

variable "alert_email" {
  description = "Alert notification email"
  type        = string
}

variable "lb_ipam_range" {
  description = "Load balancer IPAM range"
  type        = string
}

variable "artifact_url" {
  description = "OCI artifact repository URL (e.g. oci://ghcr.io/mojaloop/ml-gitops)"
  type        = string
}

variable "artifact_version" {
  description = "OCI artifact tag/version (e.g. latest, v1.0.0)"
  type        = string
  default     = "latest"
}

variable "dns_credentials" {
  description = "DNS provider credentials — provider-specific key-value pairs injected into cluster-secrets for Flux postBuild substitution"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "gateway_class_name" {
  description = "GatewayClass name for the shared Gateway (cilium on most providers, gke-specific on GCP)"
  type        = string
  default     = "cilium"
}

variable "oci_repo_username" {
  description = "OCI repo registry username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_repo_password" {
  description = "OCI repo registry password"
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

variable "infra_provider" {
  description = "Infrastructure provider name — used to conditionally deploy vendor kustomization (talos, aws, gcp)"
  type        = string
  default     = ""
}

variable "minio_root_user" {
  description = "MinIO root username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_password" {
  description = "MinIO root password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_admin_password" {
  description = "Harbor admin password"
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

# --- App Environment Data Layer ---

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

# --- App Environment Data Endpoints (cloud override) ---

variable "mysql_host" {
  description = "MySQL host (cloud: RDS endpoint)"
  type        = string
  default     = ""
}

variable "mysql_port" {
  description = "MySQL port"
  type        = string
  default     = ""
}

variable "kafka_host" {
  description = "Kafka bootstrap server host (cloud: MSK endpoint)"
  type        = string
  default     = ""
}

variable "kafka_port" {
  description = "Kafka bootstrap server port"
  type        = string
  default     = ""
}

variable "mongodb_host" {
  description = "MongoDB host (cloud: DocumentDB endpoint)"
  type        = string
  default     = ""
}

variable "mongodb_port" {
  description = "MongoDB port"
  type        = string
  default     = ""
}

variable "redis_host" {
  description = "Redis host (cloud: ElastiCache endpoint)"
  type        = string
  default     = ""
}

variable "redis_port" {
  description = "Redis port"
  type        = string
  default     = ""
}

# --- App Environment Auth Layer ---

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

# --- Alerting Delivery (Grafana contact points) ---

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

# --- Backup S3 (CC MinIO or cloud S3) ---

variable "backup_s3_endpoint" {
  description = "S3 endpoint URL for backups"
  type        = string
  default     = ""
}

variable "backup_s3_bucket" {
  description = "S3 bucket name for backups"
  type        = string
  default     = "backups"
}

variable "backup_s3_region" {
  description = "S3 region for backups"
  type        = string
  default     = "us-east-1"
}

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

# --- Observability Parameters ---

variable "loki_url" {
  description = "Loki push endpoint URL for log aggregation (cross-cluster)"
  type        = string
  default     = ""
}

variable "mimir_url" {
  description = "Mimir remote write endpoint URL for metrics aggregation (cross-cluster)"
  type        = string
  default     = ""
}

variable "tempo_url" {
  description = "Tempo OTLP/HTTP traces ingest URL (cross-cluster, e.g. https://tempo.int.<cc-domain>/v1/traces)"
  type        = string
  default     = ""
}

# --- Hub Identity ---

variable "hub_participant_name" {
  description = "Hub participant name — canonical identifier used by mojaloop chart HUB_PARTICIPANT.NAME, MCM SWITCH_ID, and DFSP onboarding HUB_NAME"
  type        = string
  default     = "Hub"
}

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

variable "api_type" {
  description = "Mojaloop API dialect — fspiop or iso20022. Substituted into ALS, quoting-service, and ml-api-adapter HelmRelease config."
  type        = string
  default     = "fspiop"

  validation {
    condition     = contains(["fspiop", "iso20022"], var.api_type)
    error_message = "api_type must be 'fspiop' or 'iso20022'."
  }
}


# --- Profile Variables (TPS/CC sizing) ---

variable "profile_vars" {
  description = "Scaling and tuning variables from TPS/CC profile, merged into cluster-config ConfigMap"
  type        = map(string)
  default     = {}
}

# --- Deployer Helm Value Overrides ---

variable "helm_value_overrides" {
  description = "Per-chart deployer override values (chart_name => raw values.yaml string). Empty string skips ConfigMap creation; HelmRelease valuesFrom entry is optional, so missing ConfigMap is a no-op."
  type        = map(string)
  default     = {}
}

