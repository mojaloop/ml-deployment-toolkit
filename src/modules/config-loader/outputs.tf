# Outputs from Config Loader Module

output "config" {
  description = "Complete environment configuration (config.yaml)"
  value       = local.config
}

output "provider_name" {
  description = "Infrastructure provider name"
  value       = local.provider_name
}

output "cluster" {
  description = "Cluster configuration (name, role, vip, lb_ipam, flux)"
  value       = local.cluster
}

output "cluster_role" {
  description = "Cluster role: tooling | hub | bare"
  value       = local.cluster_role
}

output "dns" {
  description = "DNS configuration"
  value       = local.config.dns
}

output "flux_version" {
  description = "Flux distribution version"
  value       = local.flux_version
}

# --- Topology -------------------------------------------------------------

output "instances" {
  description = "Expanded per-node instances with resolved placement (on-prem)"
  value       = local.instances
}

output "control_plane_instances" {
  description = "Control-plane instances (includes mixed-plane)"
  value       = local.control_plane_instances
}

output "worker_instances" {
  description = "Worker instances"
  value       = local.worker_instances
}

output "aws_node_groups" {
  description = "EKS node groups derived from template node groups"
  value       = local.aws_node_groups
}

output "do_node_pools" {
  description = "DOKS node pools derived from template node groups"
  value       = local.do_node_pools
}

output "workload_classes" {
  description = "Workload classes configuration"
  value       = local.workload_classes.classes
}

output "talos_version" {
  description = "Talos version (from workload-classes.yaml)"
  value       = local.talos_version
}

output "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  value       = local.kubernetes_version
}

output "talos_image" {
  description = "Talos image URL and file name"
  value = {
    url       = local.talos_image_url
    file_name = local.talos_image_file_name
  }
}

output "label_taint_patches" {
  description = "Dynamic label/taint patches per workload class"
  value       = local.label_taint_patches
}

# --- Template tuning sections ---------------------------------------------

output "template_app" {
  description = "Application scaling variables from the template"
  value       = try(local.template.app, {})
}

output "template_data" {
  description = "Data layer tuning variables from the template"
  value       = try(local.template.data, {})
}

output "template_tooling" {
  description = "Tooling services scaling variables from the template"
  value       = try(local.template.tooling, {})
}

# --- Resolved capabilities ------------------------------------------------

output "lb_ipam_pools" {
  description = "Per-gateway LB IPAM pools (resolved): name => { lan, wan, dns_target }"
  value       = local.lb_ipam_pools
}

output "registry" {
  description = "Image pull-through cache (resolved)"
  value = {
    active = local.registry_active
    url    = local.registry_url
    robots = local.registry_robots
  }
}

output "object_storage" {
  description = "Backup S3 target (resolved)"
  value = {
    active   = local.object_storage_active
    endpoint = local.backup_s3_endpoint
    bucket   = local.backup_s3_bucket
    region   = local.backup_s3_region
    buckets  = local.object_storage_buckets
  }
}

output "observability" {
  description = "Telemetry push sink URLs (resolved)"
  value = {
    loki_url  = local.loki_url
    mimir_url = local.mimir_url
    tempo_url = local.tempo_url
  }
}

output "cert" {
  description = "ACME parameters (resolved)"
  value = {
    acme_email              = local.acme_email
    acme_server             = local.acme_server
    acme_account_key_secret = local.acme_account_key_secret
  }
}

output "email" {
  description = "Transactional SMTP parameters (non-secret)"
  value = {
    host = local.smtp_host
    port = local.smtp_port
    from = local.email_from
  }
}

output "alerting" {
  description = "Alert delivery parameters (non-secret)"
  value = {
    email_to         = local.alert_email_to
    telegram_chat_id = local.telegram_chat_id
  }
}

output "data_stores" {
  description = "Per-store data layer resolution: mode, in_cluster, host, port"
  value       = local.data_stores
}

output "artifact" {
  description = "Distribution gitops artifact (resolved)"
  value = {
    active  = local.artifact_active
    url     = local.artifact_url
    version = local.artifact_version
  }
}

output "app" {
  description = "Application / hub parameters"
  value = {
    api_type                 = local.api_type
    hub_participant_name     = local.hub_participant_name
    hub_admin_email          = local.hub_admin_email
    onboarding_funds_in      = local.onboarding_funds_in
    onboarding_net_debit_cap = local.onboarding_net_debit_cap
  }
}

output "paths" {
  description = "Standard paths for shared resources (relative to a stack root)"
  value = {
    patches = "../../config/patches/talos"
  }
}
