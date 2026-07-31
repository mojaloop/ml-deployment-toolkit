# Config stack — everything Flux consumes: cluster-config, cluster-secrets,
# generated internal passwords, values overrides, OCIRepository, Kustomizations.
# Applies in seconds and cannot touch infrastructure. Flux picks up changes on
# its next reconcile cycle (postBuild.substituteFrom re-reads both objects).
#
# Run alone with: make apply-config ENV=<env>

locals {
  env_config_path = "../../environments/${var.env_name}/config.yaml"

  # Non-secret variables an override file may reference as ${var}.
  # Flux cannot substitute inside a ConfigMap it does not render, so overrides
  # are templated here instead — same ${...} syntax as the gitops manifests.
  # Secrets are deliberately absent: override files are for values, not credentials.
  override_vars = merge(
    {
      cluster_name = module.config.cluster.name
      domain       = module.config.dns.domain
      loki_url     = module.config.observability.loki_url
      mimir_url    = module.config.observability.mimir_url
      tempo_url    = module.config.observability.tempo_url
    },
    { for k, v in module.config.template_app : k => tostring(v) },
    { for k, v in module.config.template_data : k => tostring(v) },
    { for k, v in module.config.template_cc : k => tostring(v) },
  )

  # Deployer Helm value overrides — environments/<env>/values/<chart>.yaml
  values_dir = "../../environments/${var.env_name}/values"
  helm_value_overrides = {
    for f in try(fileset(local.values_dir, "*.yaml"), []) :
    trimsuffix(f, ".yaml") => templatefile("${local.values_dir}/${f}", local.override_vars)
  }
}

# Load and resolve configuration
module "config" {
  source = "../modules/config-loader"

  config_path           = local.env_config_path
  workload_classes_path = "../../config/definitions/workload-classes.yaml"
  templates_path        = "../../config/templates"
  env_name              = var.env_name
}

module "flux_config" {
  count  = module.config.artifact.active ? 1 : 0
  source = "../modules/flux-config"

  cluster_name       = module.config.cluster.name
  cluster_role       = module.config.cluster_role
  infra_provider     = module.config.provider_name
  dns_provider       = module.config.dns.provider
  domain             = module.config.dns.domain
  gateway_class_name = try(module.config.cluster.gateway_class_name, "cilium")
  lb_ipam_range      = module.config.cluster.lb_ipam.range

  artifact_url     = module.config.artifact.url
  artifact_version = module.config.artifact.version

  cert           = module.config.cert
  email          = module.config.email
  alerting       = module.config.alerting
  observability  = module.config.observability
  registry       = module.config.registry
  object_storage = module.config.object_storage
  data_stores    = module.config.data_stores
  app            = module.config.app

  secrets = var.secrets

  profile_vars = merge(
    { for k, v in module.config.template_app : k => tostring(v) },
    { for k, v in module.config.template_data : k => tostring(v) },
    { for k, v in module.config.template_cc : k => tostring(v) },
  )

  helm_value_overrides = local.helm_value_overrides
}
