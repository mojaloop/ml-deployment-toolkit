# Config Loader Module
# Loads and resolves the environment configuration:
#   environments/<env>/config.yaml   (adopter-authored, schema-validated)
#   config/templates/<role>/<template>.yaml  (generic capacity template)
#   config/templates/mappings/<provider>.yaml (provider mapping)
#   config/definitions/workload-classes.yaml  (platform definitions)
# Expands node groups into provider shapes and resolves capability bindings
# (registry, object_storage, observability, cert, email, alerting, data modes).

locals {
  # --- Raw inputs ---------------------------------------------------------
  config           = yamldecode(file(var.config_path))
  workload_classes = yamldecode(file(var.workload_classes_path))

  cluster = local.config.cluster
  # cluster.name is optional and defaults to the environment directory name.
  # It is the cluster's durable identity: it becomes the external-dns TXT owner
  # id, the Vault backup prefix, and the VM name prefix. Renaming an existing
  # cluster orphans records owned under the old name, so migrated environments
  # should set it explicitly to whatever they already use.
  cluster_name  = try(local.cluster.name, var.env_name)
  cluster_role  = local.cluster.role
  provider_name = local.config.infra.provider

  mapping  = yamldecode(file("${var.templates_path}/mappings/${local.provider_name}.yaml"))
  template = yamldecode(file("${var.templates_path}/${local.cluster_role}/${local.config.template}.yaml"))

  node_groups = try(local.template.node_groups, [])

  # On-prem providers render one VM per node and need real placement targets.
  is_talos_provider = contains(["proxmox", "openstack"], local.provider_name)
  template_placement_groups = distinct(flatten([
    for g in local.node_groups : try(g.placement, [])
  ]))

  # --- Versions (single source of truth: workload-classes.yaml) -----------
  kubernetes_version = local.workload_classes.kubernetes_version
  talos_version      = local.workload_classes.talos_version

  # Talos image URL — only for on-prem providers whose mapping defines talos.platform
  talos_image_platform  = try(local.mapping.talos.platform, "")
  talos_image_schematic = try(local.workload_classes.talos_image.schematic, "")
  talos_image_arch      = try(local.workload_classes.talos_image.arch, "amd64")
  talos_image_url = local.talos_image_platform != "" ? (
    "https://factory.talos.dev/image/${local.talos_image_schematic}/${local.talos_version}/${local.talos_image_platform}-${local.talos_image_arch}.raw.gz"
  ) : ""
  talos_image_file_name = local.talos_image_platform != "" ? (
    "talos-${local.talos_version}-${local.talos_image_arch}.img"
  ) : ""

  # --- Node-group expansion (on-prem: one VM per node) ---------------------
  # Node i of a group takes placement[i], wrapping when the list is shorter
  # than count. Placement groups resolve through infra.<provider>.placement.
  placement_map = try(local.config.infra[local.provider_name].placement, {})

  expanded_nodes = flatten([
    for g in local.node_groups : [
      for i in range(g.count) : {
        name            = "${g.name}-${i}"
        workload_class  = g.class
        cores           = g.cores
        memory          = g.memory
        storage         = [for di, size in g.disks : { interface = "scsi${di}", size = size }]
        placement_group = length(try(g.placement, [])) > 0 ? g.placement[i % length(g.placement)] : ""
        tags            = distinct(concat(["ml"], try(g.tags, [])))
      }
    ]
  ])

  instances = [
    for instance in local.expanded_nodes : merge(instance, {
      name = "${local.cluster_name}-${instance.name}"
      tags = concat(instance.tags, [local.cluster_name])
      resolved_placement = {
        placement_group = lookup(local.placement_map, instance.placement_group, instance.placement_group)
      }
    })
  ]

  # Mixed-plane counts as control-plane for bootstrap/VIP
  control_plane_instances = [
    for instance in local.instances :
    instance if contains(["control-plane", "mixed-plane"], instance.workload_class)
  ]

  worker_instances = [
    for instance in local.instances :
    instance if startswith(instance.workload_class, "worker")
  ]

  # --- Cloud shapes (managed Kubernetes: one pool per node group) ----------
  instance_types = try(local.mapping.instance_types, {})

  aws_node_groups = [
    for g in local.node_groups : {
      name           = g.name
      instance_types = [lookup(local.instance_types, g.class, "m5.xlarge")]
      desired_size   = g.count
      min_size       = g.count
      max_size       = g.count + 1
      tags           = distinct(concat(["ml"], try(g.tags, [])))
    }
  ]

  do_node_pools = [
    for g in local.node_groups : {
      name  = g.name
      size  = lookup(local.instance_types, g.class, "s-4vcpu-8gb")
      count = g.count
      tags  = distinct(concat(["ml"], try(g.tags, [])))
    }
  ]

  # --- Dynamic label/taint patches per workload class (Talos only) ---------
  label_taint_patches = {
    for class_name, class_def in local.workload_classes.classes :
    class_name => yamlencode({
      machine = merge(
        length(try(class_def.node_labels, {})) > 0 ? { nodeLabels = class_def.node_labels } : {},
        length(try(class_def.node_taints, [])) > 0 ? {
          nodeTaints = {
            for taint in class_def.node_taints :
            "${taint.key}=${taint.value}" => taint.effect
          }
        } : {}
      )
    })
    if length(try(class_def.node_labels, {})) > 0 || length(try(class_def.node_taints, [])) > 0
  }

  # =========================================================================
  # Capability resolution
  # =========================================================================
  tcc_domain = try(local.config.toolkit_cc.domain, "")

  # --- registry (image pull-through cache) ---------------------------------
  registry_provider = try(local.config.registry.provider, "none")
  registry_url = (
    local.registry_provider == "toolkit-cc" ? "harbor.int.${local.tcc_domain}" :
    local.registry_provider == "harbor" ? try(local.config.registry.url, "") :
    ""
  )
  registry_active = local.registry_url != ""

  # --- object_storage (backup target) --------------------------------------
  object_storage_provider = try(local.config.object_storage.provider, "none")
  backup_s3_endpoint = (
    local.object_storage_provider == "toolkit-cc" ? "https://s3.int.${local.tcc_domain}" :
    local.object_storage_provider == "s3" ? try(local.config.object_storage.endpoint, "") :
    ""
  )
  backup_s3_bucket = try(local.config.object_storage.bucket, "backups")
  backup_s3_region = try(local.config.object_storage.region, "us-east-1")

  # --- observability (telemetry push sink) ---------------------------------
  observability_provider = try(local.config.observability.provider, "none")
  loki_url = (
    local.observability_provider == "toolkit-cc" ? "https://loki.int.${local.tcc_domain}/loki/api/v1/push" :
    try(local.config.observability.loki_url, "")
  )
  mimir_url = (
    local.observability_provider == "toolkit-cc" ? "https://thanos.int.${local.tcc_domain}/api/v1/receive" :
    try(local.config.observability.mimir_url, "")
  )
  tempo_url = (
    local.observability_provider == "toolkit-cc" ? "https://tempo.int.${local.tcc_domain}/v1/traces" :
    try(local.config.observability.tempo_url, "")
  )

  # --- cert (ACME) ----------------------------------------------------------
  acme_email  = try(local.config.cert.email, "admin@${local.config.dns.domain}")
  acme_server = try(local.config.cert.server, "https://acme-v02.api.letsencrypt.org/directory")

  # --- email (transactional SMTP) ------------------------------------------
  smtp_host  = try(local.config.email.host, "")
  smtp_port  = tostring(try(local.config.email.port, "587"))
  email_from = try(local.config.email.from, "noreply@${local.config.dns.domain}")

  # --- alerting (delivery channels) ----------------------------------------
  alert_email_to   = try(local.config.alerting.email.to, "alerts@example.invalid")
  telegram_chat_id = tostring(try(local.config.alerting.telegram.chat_id, "0"))

  # --- data (per-store mode) -----------------------------------------------
  # in-cluster-managed: operators + CRs deployed, endpoints derived.
  # external-unmanaged: adopter-supplied endpoint/credentials, env-data slice suppressed.
  # external-managed: schema-reserved, rejected below until implemented.
  data_store_defaults = {
    mysql   = { host = "mojaloop-db-haproxy.data.svc.cluster.local", port = "3306" }
    kafka   = { host = "mojaloop-kafka-kafka-bootstrap.data.svc.cluster.local", port = "9092" }
    mongodb = { host = "bulk-mongodb-rs0.data.svc.cluster.local", port = "27017" }
    redis   = { host = "ttk-redis.data.svc.cluster.local", port = "6379" }
  }

  data_stores = {
    for store, defaults in local.data_store_defaults :
    store => {
      mode       = try(local.config.data[store].mode, "in-cluster-managed")
      in_cluster = try(local.config.data[store].mode, "in-cluster-managed") == "in-cluster-managed"
      host = (
        try(local.config.data[store].mode, "in-cluster-managed") == "in-cluster-managed"
        ? defaults.host
        : tostring(try(local.config.data[store].host, ""))
      )
      port = (
        try(local.config.data[store].mode, "in-cluster-managed") == "in-cluster-managed"
        ? defaults.port
        : tostring(try(local.config.data[store].port, defaults.port))
      )
    }
  }

  # --- artifact (distribution gitops source) -------------------------------
  artifact_url     = try(local.config.artifact.url, "")
  artifact_version = try(local.config.artifact.version, "latest")
  artifact_active  = try(local.config.artifact.active, local.artifact_url != "")

  # --- app / hub parameters -------------------------------------------------
  api_type                 = try(local.config.app.api_type, "fspiop")
  hub_participant_name     = try(local.config.app.hub.participant_name, "Hub")
  hub_admin_email          = try(local.config.app.hub.admin_email, "")
  onboarding_funds_in      = tostring(try(local.config.app.hub.onboarding.funds_in, "100000"))
  onboarding_net_debit_cap = tostring(try(local.config.app.hub.onboarding.net_debit_cap, "1000"))

  flux_version = try(local.cluster.flux.version, "2.7.2")
}

# Cross-field validation that JSON Schema cannot express.
resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = try(local.config.version, 0) == 1
      error_message = "config.yaml must declare 'version: 1' (schema version)."
    }
    precondition {
      condition     = contains(["cc", "env", "base"], local.cluster_role)
      error_message = "cluster.role must be one of: cc, env, base."
    }
    precondition {
      condition     = local.cluster_name != ""
      error_message = "cluster.name resolved to an empty string — set it, or name the environment directory."
    }
    precondition {
      condition = alltrue([
        for p in [local.registry_provider, local.object_storage_provider, local.observability_provider] :
        p != "toolkit-cc"
      ]) || local.tcc_domain != ""
      error_message = "A capability uses provider 'toolkit-cc' but toolkit_cc.domain is not set."
    }
    precondition {
      condition = alltrue([
        for store, cfg in local.data_stores : cfg.mode != "external-managed"
      ])
      error_message = "data mode 'external-managed' is schema-reserved and not implemented yet — use in-cluster-managed or external-unmanaged."
    }
    precondition {
      condition = alltrue([
        for store, cfg in local.data_stores :
        cfg.mode == "in-cluster-managed" || cfg.host != ""
      ])
      error_message = "external-unmanaged data stores must set data.<store>.host."
    }
    precondition {
      condition     = local.cluster_role != "env" || contains(["fspiop", "iso20022"], local.api_type)
      error_message = "app.api_type must be fspiop or iso20022."
    }

    # The in-cluster data layer is only packaged for Talos providers. Without
    # this, a managed-Kubernetes hub reconciles green while cluster-config
    # advertises in-cluster hostnames that were never deployed, and every app
    # pod CrashLoops on DNS.
    precondition {
      condition = (
        local.cluster_role != "env" || local.is_talos_provider ||
        alltrue([for store, cfg in local.data_stores : !cfg.in_cluster])
      )
      error_message = "infra.provider '${local.provider_name}' has no in-cluster data layer — every data.<store>.mode must be external-unmanaged on this provider."
    }

    # Placement groups referenced by the template must be mapped to real targets;
    # otherwise the provider is handed the literal group name as a node name and
    # fails partway through apply with VMs already created.
    precondition {
      condition = (
        !local.is_talos_provider ||
        alltrue([
          for g in local.node_groups : alltrue([
            for pg in try(g.placement, []) : contains(keys(local.placement_map), pg)
          ])
        ])
      )
      error_message = "template '${local.config.template}' references placement groups that infra.${local.provider_name}.placement does not map: ${join(", ", setsubtract(local.template_placement_groups, keys(local.placement_map)))}."
    }

    # Node group names become VM name suffixes and for_each keys.
    precondition {
      condition     = length(local.node_groups) == length(distinct([for g in local.node_groups : g.name]))
      error_message = "template '${local.config.template}' has duplicate node_group names."
    }

    # Capabilities bound to an explicit provider must carry their parameters,
    # or the value silently reaches the cluster empty and fails at runtime.
    precondition {
      condition     = local.registry_provider != "harbor" || local.registry_url != ""
      error_message = "registry.provider is 'harbor' but registry.url is not set."
    }
    precondition {
      condition     = local.object_storage_provider != "s3" || local.backup_s3_endpoint != ""
      error_message = "object_storage.provider is 's3' but object_storage.endpoint is not set."
    }
    precondition {
      condition = (
        local.observability_provider != "urls" ||
        (local.loki_url != "" || local.mimir_url != "" || local.tempo_url != "")
      )
      error_message = "observability.provider is 'urls' but no loki_url/mimir_url/tempo_url is set."
    }
  }
}
