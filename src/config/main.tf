# Config stack — everything Flux consumes: cluster-config, cluster-secrets,
# generated internal passwords, values overrides, OCIRepository, Kustomizations.
# Applies in seconds and cannot touch infrastructure. Flux picks up changes on
# its next reconcile cycle (postBuild.substituteFrom re-reads both objects).
#
# Run alone with: make apply-config ENV=<env>

locals {
  env_dir         = "${var.environments_dir}/${var.env_name}"
  env_config_path = "${local.env_dir}/config.yaml"

  # Non-secret variables an override file may reference as ${UPPER_SNAKE}.
  # Flux cannot substitute inside a ConfigMap it does not render, so overrides
  # are templated here instead — same ${...} syntax as the gitops manifests.
  # Parameters come from config.yaml/.env ONLY — template tuning is expressed
  # as values/patches overlays (composition), never as substitution variables.
  override_vars = {
    CLUSTER_NAME = module.config.cluster.name
    DOMAIN       = module.config.dns.domain
    LOKI_URL     = module.config.observability.loki_url
    MIMIR_URL    = module.config.observability.mimir_url
    TEMPO_URL    = module.config.observability.tempo_url
  }

  # Deployer Helm value overrides — <env>/values/<namespace>/<release>.yaml,
  # keyed <namespace>-<release>.
  #
  # SECRETS RULE: a file that references any ${SECRET_KEY} from .env becomes a
  # Secret (templated with override_vars + secrets); every other file becomes a
  # ConfigMap and is templated with override_vars ONLY — so a secret reference
  # that slipped past classification, or any undeclared token, hard-fails at
  # plan time (templatefile errors on undefined variables). That failure is the
  # decided behavior, not an accident.
  values_dir = "${local.env_dir}/values"
  # Key NAMES are not secret material — strip the sensitive mark so the
  # classification below cannot taint the non-secret (ConfigMap) map, whose
  # keys must be usable in for_each.
  secret_keys = nonsensitive(keys(var.secrets))

  # Template-layer gitops deltas — the middle slot of the three-layer chain
  # (common -> template -> environment). Same layout and templating as the
  # environment's values/ and patches/, but DTK-authored: secrets are
  # forbidden, so files are templated with override_vars only and any secret
  # reference hard-fails at plan.
  template_values_dir = "${module.config.template_dir}/values"
  template_value_overrides = {
    for f in try(fileset(local.template_values_dir, "*/*.yaml"), []) :
    replace(trimsuffix(f, ".yaml"), "/", "-") => templatefile("${local.template_values_dir}/${f}", local.override_vars)
  }

  template_patches_dir = "${module.config.template_dir}/patches"
  template_patches = {
    for f in try(fileset(local.template_patches_dir, "*.yaml"), []) :
    trimsuffix(f, ".yaml") => [
      for doc in yamldecode(templatefile("${local.template_patches_dir}/${f}", local.override_vars)) :
      merge(
        { patch = try(tostring(doc.patch), yamlencode(doc.patch), yamlencode(doc)) },
        can(doc.target) ? { target = doc.target } : {},
      )
    ]
  }

  helm_value_files = {
    for f in try(fileset(local.values_dir, "*/*.yaml"), []) :
    replace(trimsuffix(f, ".yaml"), "/", "-") => "${local.values_dir}/${f}"
  }

  # True when the raw file references at least one secret key. Guarded so an
  # empty secrets map cannot yield a match-anything alternation.
  helm_value_refs_secret = {
    for k, path in local.helm_value_files :
    k => length(local.secret_keys) > 0 && length(regexall("\\$\\{(${join("|", local.secret_keys)})\\}", file(path))) > 0
  }

  helm_value_overrides = {
    for k, path in local.helm_value_files :
    k => templatefile(path, local.override_vars) if !local.helm_value_refs_secret[k]
  }

  helm_value_secret_overrides = {
    for k, path in local.helm_value_files :
    k => templatefile(path, merge(local.override_vars, var.secrets)) if local.helm_value_refs_secret[k]
  }

  # Deployer kustomize patches — environments/<env>/patches/<kustomization>.yaml
  # (flat, keyed by Kustomization name — NOT the namespaced values/ layout).
  # Reaches what Helm values cannot: the CRs of the data layer and every other
  # plain manifest the distribution ships. Templated with override_vars ONLY:
  # patches become Flux Kustomization patches, never a Secret, so secret
  # references in patches remain forbidden and hard-fail at plan time.
  #
  # Each file is a list whose elements are either a partial resource (kustomize
  # infers the target from apiVersion/kind/metadata.name) or an explicit
  # { patch, target } entry — the latter for JSON 6902 ops, which a strategic
  # merge cannot express. The try() chain distinguishes them: a string `patch`
  # passes through, a structured one is encoded, and anything without a `patch`
  # key is the resource itself.
  patches_dir = "${local.env_dir}/patches"
  kustomize_patches = {
    for f in try(fileset(local.patches_dir, "*.yaml"), []) :
    trimsuffix(f, ".yaml") => [
      for doc in yamldecode(templatefile("${local.patches_dir}/${f}", local.override_vars)) :
      merge(
        { patch = try(tostring(doc.patch), yamlencode(doc.patch), yamlencode(doc)) },
        can(doc.target) ? { target = doc.target } : {},
      )
    ]
  }
}

# Load and resolve configuration
module "config" {
  source = "../modules/config-loader"

  config_path           = local.env_config_path
  workload_classes_path = "../../config/definitions/workload-classes.yaml"
  templates_path        = "../../config/templates"
  env_name              = var.env_name
  env_dir               = local.env_dir
  dtk_tag               = var.dtk_tag
}

module "flux_config" {
  count  = module.config.artifact.active ? 1 : 0
  source = "../modules/flux-config"

  cluster_name   = module.config.cluster.name
  cluster_role   = module.config.cluster_role
  infra_provider = module.config.provider_name
  dns_provider   = module.config.dns.provider
  domain         = module.config.dns.domain
  lb_ipam_pools  = module.config.lb_ipam_pools

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

  # Provider symbols (P_*, already UPPER_SNAKE) for cluster-config.
  params = module.config.provider_params

  template_value_overrides    = local.template_value_overrides
  template_patches            = local.template_patches
  helm_value_overrides        = local.helm_value_overrides
  helm_value_secret_overrides = local.helm_value_secret_overrides
  kustomize_patches           = local.kustomize_patches
}
