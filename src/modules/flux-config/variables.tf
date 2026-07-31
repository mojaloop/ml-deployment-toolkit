# Variables for the Flux Config module (config stack)

variable "flux_namespace" {
  description = "Kubernetes namespace for Flux resources"
  type        = string
  default     = "flux-system"
}

variable "cluster_name" {
  description = "Cluster name"
  type        = string
}

variable "cluster_role" {
  description = "Cluster role — determines which gitops paths are deployed"
  type        = string

  validation {
    condition     = contains(["base", "cc", "env"], var.cluster_role)
    error_message = "cluster_role must be 'base', 'cc', or 'env'."
  }
}

variable "infra_provider" {
  description = "Infrastructure provider (selects vendor kustomization)"
  type        = string
}

variable "dns_provider" {
  description = "DNS provider (selects gitops/dns/<provider>)"
  type        = string
}

variable "domain" {
  description = "Base domain of this cluster"
  type        = string
}

variable "gateway_class_name" {
  description = "GatewayClass name for the Gateways"
  type        = string
  default     = "cilium"
}

variable "lb_ipam_range" {
  description = "Cilium LB-IPAM range (start-stop)"
  type        = string
}

variable "artifact_url" {
  description = "OCI URL of the gitops artifact"
  type        = string
}

variable "artifact_version" {
  description = "OCI tag of the gitops artifact"
  type        = string
  default     = "latest"
}

# --- Capability resolutions (from config-loader) ---------------------------

variable "cert" {
  description = "ACME parameters: acme_email, acme_server"
  type = object({
    acme_email  = string
    acme_server = string
  })
}

variable "email" {
  description = "Transactional SMTP parameters (non-secret): host, port, from"
  type = object({
    host = string
    port = string
    from = string
  })
}

variable "alerting" {
  description = "Alert delivery parameters (non-secret): email_to, telegram_chat_id"
  type = object({
    email_to         = string
    telegram_chat_id = string
  })
}

variable "observability" {
  description = "Telemetry push sink URLs: loki_url, mimir_url, tempo_url"
  type = object({
    loki_url  = string
    mimir_url = string
    tempo_url = string
  })
}

variable "object_storage" {
  description = "Backup S3 target: endpoint, bucket, region; active is false when provider is 'none'"
  type = object({
    active   = bool
    endpoint = string
    bucket   = string
    region   = string
  })
}

variable "data_stores" {
  description = "Per-store data layer resolution: mode, in_cluster, host, port"
  type = map(object({
    mode       = string
    in_cluster = bool
    host       = string
    port       = string
  }))
  default = {}
}

variable "app" {
  description = "Application / hub parameters"
  type = object({
    api_type                 = string
    hub_participant_name     = string
    hub_admin_email          = string
    onboarding_funds_in      = string
    onboarding_net_debit_cap = string
  })
}

# --- Secrets ---------------------------------------------------------------

# Raw external credentials from environments/<env>/.env, passed as one map by
# the Makefile (keys are the .env variable names). Any generated-secret name
# present here (upper-cased, non-empty) overrides generation — this is how
# external-unmanaged data stores supply their own passwords.
variable "secrets" {
  description = "External credentials map from .env (keys = env var names)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

# --- Template tuning + overrides ------------------------------------------

variable "profile_vars" {
  description = "Template tuning variables (app/data/cc sections, flattened) for postBuild substitution"
  type        = map(string)
  default     = {}
}

variable "helm_value_overrides" {
  description = "Per-chart Helm values overrides (chart name -> values.yaml content)"
  type        = map(string)
  default     = {}
}
