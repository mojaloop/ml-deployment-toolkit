# Main Terraform configuration
# Orchestrates infrastructure deployment using YAML configuration files

locals {
  # Per-environment config path (driven by env_name variable)
  env_config_path = "../config/environments/${var.env_name}/config.yaml"
  artifacts_path  = "../artifacts/${var.env_name}"

  # Read base config to determine provider and OCI repo active state
  config_raw    = yamldecode(file(local.env_config_path))
  provider_name = local.config_raw.infra.provider
  oci_active    = try(local.config_raw.oci.repo.active, false)
  is_talos      = contains(["proxmox", "openstack"], local.provider_name)

  # Config-loader outputs
  config = module.config.config

  # Provider output map — avoids ternary chains; adding a new provider requires one new entry
  provider_outputs = {
    proxmox      = length(module.proxmox) > 0 ? module.proxmox[0] : null
    digitalocean = length(module.digitalocean) > 0 ? module.digitalocean[0] : null
    aws          = length(module.aws) > 0 ? module.aws[0] : null
  }
  active_provider = try(local.provider_outputs[local.provider_name], null)

  # Kubeconfig path — derived from provider module output (local_sensitive_file.filename).
  # This is an input attribute, so it's known at plan time even for new resources,
  # while the reference defers provider configuration until the file is written.
  # IMPORTANT: access the kubeconfig_path output directly, NOT via local.active_provider.
  # The active_provider object contains plan-unknown outputs (e.g. bootstrap_complete),
  # and `!= null` on such an object evaluates to unknown — which made config_path
  # unknown at plan time and broke kubectl provider configuration ("no configuration
  # has been provided").
  kubeconfig_paths = {
    proxmox      = length(module.proxmox) > 0 ? module.proxmox[0].kubeconfig_path : null
    digitalocean = length(module.digitalocean) > 0 ? module.digitalocean[0].kubeconfig_path : null
    aws          = length(module.aws) > 0 ? module.aws[0].kubeconfig_path : null
  }
  kubeconfig_path = try(local.kubeconfig_paths[local.provider_name], null)
}

# Load configuration from YAML files
module "config" {
  source = "./modules/config-loader"

  config_path           = local.env_config_path
  workload_classes_path = "../config/definitions/workload-classes.yaml"
}

# Proxmox Cluster
module "proxmox" {
  count  = local.provider_name == "proxmox" ? 1 : 0
  source = "./modules/proxmox"

  instances           = module.config.instances
  cluster             = module.config.cluster
  workload_classes    = module.config.workload_classes
  talos_version       = module.config.talos_version
  kubernetes_version  = module.config.kubernetes_version
  talos_image         = module.config.talos_image
  label_taint_patches = module.config.label_taint_patches

  patches_path         = module.config.paths.patches
  artifacts_path       = local.artifacts_path
  provider_config_path = "../config/providers/proxmox/config.yaml"

  oci_proxy_active   = try(local.config_raw.oci.proxy.active, false)
  oci_proxy_url      = try(local.config_raw.oci.proxy.url, "")
  oci_proxy_username = var.oci_proxy_username
  oci_proxy_password = var.oci_proxy_password

  nameservers             = try(local.config_raw.infra.talos.nameservers, [])
  ntp_servers             = try(local.config_raw.infra.talos.ntp_servers, [])
  network_bridge_override = try(local.config_raw.infra.proxmox.network_bridge, "")
  storage_override = {
    disks    = try(local.config_raw.infra.proxmox.storage.disks, "")
    images   = try(local.config_raw.infra.proxmox.storage.images, "")
    snippets = try(local.config_raw.infra.proxmox.storage.snippets, "")
  }
}

# DigitalOcean Cluster (DOKS Managed Kubernetes)
module "digitalocean" {
  count  = local.provider_name == "digitalocean" ? 1 : 0
  source = "./modules/digitalocean"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_pools         = try(module.config.deployment_template.node_pools, [])

  artifacts_path       = local.artifacts_path
  provider_config_path = "../config/providers/digitalocean/config.yaml"

  region = try(local.config_raw.infra.digitalocean.region, "nyc1")
}

# AWS Cluster (EKS Managed Kubernetes)
module "aws" {
  count  = local.provider_name == "aws" ? 1 : 0
  source = "./modules/aws"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_groups        = try(module.config.deployment_template.node_groups, [])

  artifacts_path       = local.artifacts_path
  provider_config_path = "../config/providers/aws/config.yaml"

  region = try(local.config_raw.infra.aws.region, "us-east-1")
}

# FluxCD Bootstrap - install controllers (always)
module "flux_bootstrap" {
  count  = local.provider_name != "" ? 1 : 0
  source = "./modules/flux-bootstrap"

  flux_version = local.config_raw.cluster.flux.version

  depends_on = [
    module.proxmox,
    module.digitalocean,
    module.aws
  ]
}

# FluxCD Config - OCI source + Kustomization (only when oci.repo.active is true)
module "flux_config" {
  count  = local.oci_active ? 1 : 0
  source = "./modules/flux-config"

  cluster_name       = local.config.cluster.name
  cluster_role       = local.config.cluster.role
  cluster_vip        = try(local.config.cluster.vip, "")
  domain             = local.config.dns.domain
  dns_provider       = local.config.dns.provider
  gateway_class_name = try(local.config_raw.cluster.gateway_class_name, "cilium")
  alert_email        = local.config.app.alert_email
  lb_ipam_range      = local.config.app.lb_ipam.range
  artifact_url       = local.config_raw.oci.repo.url
  artifact_version   = try(local.config_raw.oci.repo.version, "latest")

  infra_provider = local.provider_name

  dns_credentials    = var.dns_credentials
  oci_repo_username  = var.oci_repo_username
  oci_repo_password  = var.oci_repo_password
  oci_proxy_username = var.oci_proxy_username
  oci_proxy_password = var.oci_proxy_password

  minio_root_user        = var.minio_root_user
  minio_root_password    = var.minio_root_password
  harbor_admin_password  = var.harbor_admin_password
  grafana_admin_password = var.grafana_admin_password

  mysql_root_password           = var.mysql_root_password
  mysql_central_ledger_password = var.mysql_central_ledger_password
  mysql_account_lookup_password = var.mysql_account_lookup_password
  mysql_oracle_msisdn_password  = var.mysql_oracle_msisdn_password
  mongodb_root_password         = var.mongodb_root_password
  mongodb_app_password          = var.mongodb_app_password

  keycloak_db_password    = var.keycloak_db_password
  kratos_db_password      = var.kratos_db_password
  keto_db_password        = var.keto_db_password
  mcm_db_password         = var.mcm_db_password
  hydra_db_password       = var.hydra_db_password
  hub_admin_password      = var.hub_admin_password
  hub_admin_email         = var.hub_admin_email
  hubop_oidc_secret       = var.hubop_oidc_secret
  mcm_oidc_client_secret  = var.mcm_oidc_client_secret
  role_assign_svc_secret  = var.role_assign_svc_secret
  dfsp_oidc_client_secret = var.dfsp_oidc_client_secret

  smtp_host     = var.smtp_host
  smtp_port     = var.smtp_port
  smtp_user     = var.smtp_user
  smtp_password = var.smtp_password

  alert_email_from   = var.alert_email_from
  alert_email_to     = var.alert_email_to
  telegram_bot_token = var.telegram_bot_token
  telegram_chat_id   = var.telegram_chat_id

  hub_participant_name     = var.hub_participant_name
  onboarding_funds_in      = var.onboarding_funds_in
  onboarding_net_debit_cap = var.onboarding_net_debit_cap

  api_type = try(local.config.app.api_type, "fspiop")

  backup_s3_endpoint   = try(local.config_raw.backup.s3.endpoint, "")
  backup_s3_bucket     = try(local.config_raw.backup.s3.bucket, "backups")
  backup_s3_region     = try(local.config_raw.backup.s3.region, "us-east-1")
  backup_s3_access_key = var.backup_s3_access_key
  backup_s3_secret_key = var.backup_s3_secret_key

  loki_url  = try(local.config_raw.observability.loki_url, "")
  mimir_url = try(local.config_raw.observability.mimir_url, "")
  tempo_url = try(local.config_raw.observability.tempo_url, "")

  profile_vars = merge(
    try({ for k, v in module.config.profile_app : k => tostring(v) }, {}),
    try({ for k, v in module.config.profile_data : k => tostring(v) }, {}),
    try({ for k, v in module.config.profile_cc : k => tostring(v) }, {}),
  )

  helm_value_overrides = {
    mojaloop = try(file("../config/environments/${var.env_name}/values/mojaloop.yaml"), "")
    mcm      = try(file("../config/environments/${var.env_name}/values/mcm.yaml"), "")
  }

  depends_on = [
    module.flux_bootstrap
  ]
}
