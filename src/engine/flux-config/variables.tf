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
    condition     = contains(["bare", "tooling", "hub"], var.cluster_role)
    error_message = "cluster_role must be 'bare', 'tooling', or 'hub'."
  }
}

variable "infra_provider" {
  description = "Infrastructure provider (selects vendor kustomization)"
  type        = string
}

variable "in_cluster_data" {
  description = "Provider capability (params.yaml capabilities.in_cluster_data): the in-cluster data layer is packaged on this provider, so hub-data Kustomizations may be generated"
  type        = bool
  default     = false
}

variable "k8s_api" {
  description = "External Kubernetes API endpoint (host + port), parsed from the infra stack's kubeconfig artifact. Consumed by cloud vendor layers whose CNI cannot rely on the in-cluster Service VIP (EKS: Cilium kube-proxy replacement needs the real endpoint)."
  type = object({
    host = string
    port = string
  })
  default = { host = "", port = "" }
}

variable "dns_provider" {
  description = "DNS provider (selects gitops/dns/<provider>)"
  type        = string
}

variable "domain" {
  description = "Base domain of this cluster"
  type        = string
}

variable "lb_ipam_pools" {
  description = "Per-gateway LB IPAM pools: name => { lan, wan, dns_target }"
  type = map(object({
    lan        = string
    wan        = string
    dns_target = string
  }))
  default = {}
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
  description = "ACME parameters: acme_email, acme_server, acme_account_key_secret"
  type = object({
    acme_email              = string
    acme_server             = string
    acme_account_key_secret = string
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
  description = "Telemetry push sink URLs (loki_url, mimir_url, tempo_url) + ingest_users, tooling-only: ingest accounts to provision in the obs-ingest front, each with a generated password."
  type = object({
    loki_url     = string
    mimir_url    = string
    tempo_url    = string
    ingest_users = list(string)
  })
}

variable "registry" {
  description = "Image pull-through cache: active, url. robots is tooling-only: pull-only robot accounts to provision in the toolkit Harbor, each with a generated secret."
  type = object({
    active = bool
    url    = string
    robots = list(string)
  })
  default = {
    active = false
    url    = ""
    robots = []
  }
}

variable "object_storage" {
  description = "Backup S3 target: endpoint, bucket, region; active is false when provider is 'none'. buckets is tooling-only: extra buckets served by the toolkit MinIO, each with a generated scoped user."
  type = object({
    active   = bool
    endpoint = string
    bucket   = string
    region   = string
    buckets  = list(string)
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
# the Makefile (keys are the .env variable names, UPPER_SNAKE). Any
# generated-secret name present here non-empty overrides generation — this is
# how external-unmanaged data stores supply their own passwords.
variable "secrets" {
  description = "External credentials map from .env (keys = env var names)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

# --- Overrides -------------------------------------------------------------

# Provider symbols (P_*) merged into the cluster-config ConfigMap. Keys arrive
# already UPPER_SNAKE and must not collide with any base config key — the
# cluster_config precondition fails listing the collisions otherwise.
variable "params" {
  description = "Provider symbols (P_*, already UPPER_SNAKE) merged into cluster-config"
  type        = map(string)
  default     = {}
}

variable "template_value_overrides" {
  description = "Template-layer Helm values (<namespace>-<release> -> templated values.yaml content from the selected template's values/), delivered as ConfigMaps named *-values-template"
  type        = map(string)
  default     = {}
}

variable "helm_value_overrides" {
  description = "Non-secret Helm values overrides (<namespace>-<release> -> templated values.yaml content), delivered as ConfigMaps"
  type        = map(string)
  default     = {}
}

variable "helm_value_secret_overrides" {
  description = "Secret-referencing Helm values overrides (<namespace>-<release> -> templated values.yaml content), delivered as Secrets"
  type        = map(string)
  default     = {}
  sensitive   = true
}

# Deliberately `any`: each value is a list of Flux patch entries whose elements
# differ in shape (a bare `patch`, or `patch` + `target`), which no concrete
# type constraint accepts. Keys naming no Kustomization are dropped downstream.
variable "kustomize_patches" {
  description = "Per-Kustomization kustomize patches (kustomization name -> list of Flux spec.patches entries)"
  type        = any
  default     = {}
}

variable "template_patches" {
  description = "Template-layer kustomize patches (kustomization name -> list of Flux spec.patches entries), applied after distribution patches and before environment patches"
  type        = any
  default     = {}
}
