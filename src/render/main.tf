# Render stack — resource-free export of the engine's resolved configuration.
#
# `make render ENV=<env>` plans this stack (plan only, never apply: it owns no
# real resources) and extracts the `resolved` output from the plan JSON into
# <RENDER_ROOT>/<env>/resolved.yaml. Because it instantiates the SAME
# config-loader module the infra and config stacks consume, the exported
# document is the actual three-layer merge — not a reimplementation that could
# drift — and every config-loader precondition runs at render time, which is
# earlier and cheaper than a plan against real infrastructure.
#
# Determinism: the output contains no timestamps, no absolute paths and no
# secrets (config-loader never sees .env); tools/render.sh serializes it with
# sorted keys, so renders are byte-stable golden files.

locals {
  env_dir = "${var.environments_dir}/${var.env_name}"
}

module "config" {
  source = "../engine/config-loader"

  config_path           = "${local.env_dir}/config.yaml"
  workload_classes_path = "../../config/definitions/workload-classes.yaml"
  providers_path        = "../../providers"
  env_name              = var.env_name
  env_dir               = local.env_dir
  dtk_tag               = var.dtk_tag
}

output "resolved" {
  description = "The materialized per-environment configuration document — the single merge result both executors consume (design doc §3: one materialized result)."
  value = {
    cluster = {
      name = module.config.cluster.name
      role = module.config.cluster_role
      vip  = try(module.config.cluster.vip, null)
    }
    provider     = module.config.provider_name
    template     = module.config.config.template
    dns          = module.config.dns
    capabilities = module.config.capabilities
    params       = module.config.provider_params
    versions = {
      talos      = module.config.talos_version
      kubernetes = module.config.kubernetes_version
      flux       = module.config.flux_version
    }

    # Topology: the pool merge result (template shape + env overrides, the
    # declared shallow per-field replacement) and its per-node expansion.
    pools           = module.config.pools
    pool_names      = module.config.pool_names
    instances       = module.config.instances
    aws_node_groups = module.config.aws_node_groups
    do_node_pools   = module.config.do_node_pools

    # Machine-config projection: the mechanically derived per-pool
    # label/taint patches (the gitops<->placement contract surface).
    pool_label_taint_patches = module.config.label_taint_patches

    # Resolved capability bindings — endpoints as stated, secrets excluded.
    lb_ipam_pools  = module.config.lb_ipam_pools
    registry       = module.config.registry
    object_storage = module.config.object_storage
    observability  = module.config.observability
    cert           = module.config.cert
    email          = module.config.email
    alerting       = module.config.alerting
    data_stores    = module.config.data_stores
    artifact       = module.config.artifact
    app            = module.config.app
  }
}
