# Config Loader Module
# Loads and resolves the environment configuration:
#   <env>/config.yaml                 (adopter-authored, schema-validated)
#   <env>/placement.yaml              (adopter-authored, node placement facts)
#   <env>/proxmox/proxmox.yaml        (adopter-authored, provider infra facts)
#   config/templates/<provider>/<role>/<template>/  (full-overlay template directory)
#   config/templates/<provider>/params.yaml  (provider interface + infra config)
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

  # Provider parameters: the interface symbols (params, P_*) plus the
  # Terraform-consumed provider config (infra — formerly the mapping file).
  provider_params_file = yamldecode(file("${var.templates_path}/${local.provider_name}/params.yaml"))
  provider_params      = try(local.provider_params_file.params, {})
  mapping              = try(local.provider_params_file.infra, {})

  # A template is a directory — the full overlay for one provider, role and
  # capacity: template.yaml (identity + tuning), placement.yaml (the shape:
  # node pools, default topology), values/ and patches/ (gitops deltas),
  # talos/<pool>.yaml (per-pool machine-config fragments).
  template_dir       = "${var.templates_path}/${local.provider_name}/${local.cluster_role}/${local.config.template}"
  template           = yamldecode(file("${local.template_dir}/template.yaml"))
  template_placement = yamldecode(file("${local.template_dir}/placement.yaml"))

  # --- VM pools merge by name ---------------------------------------------
  # Template owns the shape; the environment owns the instance. Environment
  # placement.yaml `pools:` entries deep-merge onto the template pool of the
  # same name (changing count inherits everything else), unknown names add
  # extra pools, and `enabled: false` drops a default pool — visible in the
  # environment file as a deliberate decision rather than an absence.
  template_pools     = { for g in try(local.template_placement.node_groups, []) : g.name => g }
  env_pool_overrides = try(local.placement_doc.pools, {})
  merged_pools = merge(
    { for name, g in local.template_pools : name => merge(g, try(local.env_pool_overrides[name], {})) },
    { for name, o in local.env_pool_overrides : name => merge({ name = name }, o) if !contains(keys(local.template_pools), name) },
  )
  node_groups = [for name, g in local.merged_pools : g if try(g.enabled, true)]

  # On-prem providers render one VM per node and need real placement targets.
  is_talos_provider = contains(["proxmox", "openstack"], local.provider_name)

  # --- LB IPAM (on-prem): one dedicated single-IP pool per gateway ----------
  # dns_target is what external-dns publishes for everything attached to the
  # gateway: the wan side of the border 1:1 DNAT when set, the lan IP otherwise.
  lb_ipam_pools = {
    for name, pool in try(local.cluster.lb_ipam.pools, {}) :
    name => {
      lan        = pool.lan
      wan        = try(pool.wan, "")
      dns_target = try(pool.wan, pool.lan)
    }
  }
  hub_only_pools = ["gw-extapi", "gw-intapi"]
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
  # Placement is an adopter fact (which physical node each group lands on) and
  # lives beside config.yaml as placement.yaml — it drives both the VM side and
  # the node-labelling side, and it is the file adopters edit most.
  # Condition inside yamldecode: both branches are strings, so the conditional
  # type-unifies (the decoded object type cannot unify with object({})). NOT
  # try(): a malformed placement.yaml must fail the plan loudly.
  placement_file = var.env_dir != "" ? "${var.env_dir}/placement.yaml" : ""
  placement_doc = yamldecode(
    (local.placement_file != "" && fileexists(local.placement_file)) ? file(local.placement_file) : "{}"
  )
  placement_map = try(local.placement_doc.placement, {})

  expanded_nodes = flatten([
    for g in local.node_groups : [
      for i in range(g.count) : {
        name            = "${g.name}-${i}"
        group           = g.name
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
  # Per-POOL machine-config patch: the node label derives MECHANICALLY from the
  # pool name (<P_NODE_ROLE_LABEL_KEY>=<pool>) — never typed by hand, so the
  # Talos side and the gitops selectors cannot drift. Taints are declared by
  # the pool itself in placement.yaml, once.
  node_role_label_key = try(local.provider_params.P_NODE_ROLE_LABEL_KEY, "node-role")
  pool_label_taint_patches = {
    for name, g in local.merged_pools :
    name => yamlencode({
      machine = merge(
        { nodeLabels = { (local.node_role_label_key) = name } },
        length(try(g.taints, [])) > 0 ? {
          nodeTaints = {
            for taint in g.taints :
            "${taint.key}=${try(taint.value, "")}" => taint.effect
          }
        } : {}
      )
    })
    if try(g.enabled, true)
  }

  # =========================================================================
  # Capability resolution
  # =========================================================================
  # Every capability endpoint is stated outright in config.yaml. Nothing is
  # derived from a domain and nothing falls back to a default, so what the
  # adopter reads in the file is what the cluster is pointed at. The empty
  # defaults below exist only so the preconditions can report a missing value
  # by name; a blank value never reaches an apply.

  # --- registry (image pull-through cache) ---------------------------------
  registry_active = try(local.config.registry.enabled, false)
  registry_url    = local.registry_active ? try(local.config.registry.url, "") : ""

  # tooling role only: pull-only robot accounts provisioned in the toolkit Harbor,
  # one per consuming hub (it authenticates as robot-<name>; the secret is
  # generated). Creation is additive — removing an entry stops managing the
  # robot but never deletes it in Harbor.
  registry_robots = [for r in try(local.config.registry.robots, []) : r.name]

  # --- object_storage (backup target) --------------------------------------
  # 'enabled = false' must translate into backups being structurally disabled
  # downstream: PSMDB >=1.22 refuses to mark the cluster ready (and to create
  # app users) while PBM's storage is unconfigured or unreachable, so an empty
  # endpoint must never reach the data-layer CRs. That is why this is an
  # explicit switch rather than "endpoint absent means off".
  object_storage_active = try(local.config.object_storage.enabled, false)
  backup_s3_endpoint    = try(local.config.object_storage.endpoint, "")
  # No defaults for bucket/region. 'backups' and 'us-east-1' used to be filled
  # in silently, which sent a cluster's backups to an unnamed bucket and signed
  # them for the wrong region — both failing at backup time, not at plan time.
  backup_s3_bucket = try(local.config.object_storage.bucket, "")
  backup_s3_region = try(local.config.object_storage.region, "")

  # tooling role only: extra buckets served by the toolkit MinIO, each backed by a
  # generated scoped user (access key = bucket name). Creation is additive —
  # the system buckets below always exist and cannot be re-declared, and
  # removing an entry never deletes data.
  object_storage_buckets = [for b in try(local.config.object_storage.buckets, []) : b.name]
  # Mirrors the default buckets list in gitops/tooling-config/minio/minio-values.yaml.
  minio_system_buckets = ["harbor", "backups", "thanos", "loki", "tempo"]

  # --- observability (telemetry push sink) ---------------------------------
  observability_active = try(local.config.observability.enabled, false)
  loki_url             = local.observability_active ? try(local.config.observability.loki_url, "") : ""
  mimir_url            = local.observability_active ? try(local.config.observability.mimir_url, "") : ""
  tempo_url            = local.observability_active ? try(local.config.observability.tempo_url, "") : ""

  # tooling role only: telemetry-ingest accounts served by the obs-ingest
  # front, one per pushing cluster (it authenticates as <name>; the password
  # is generated). Creation is additive — removing an entry stops managing
  # the account.
  observability_ingest_users = [for u in try(local.config.observability.ingest_users, []) : u.name]

  # --- cert (ACME) ----------------------------------------------------------
  # The directory URL is the provider identity — there is no provider enum, so
  # any current or future ACME CA is reachable by setting cert.server alone.
  # EAB credentials, where the CA requires them, arrive through .env.
  # cert.server is schema-required and deliberately has no fallback: defaulting
  # it would hide which authority the platform's certificates come from. The
  # empty default here only exists so the precondition below can report it.
  # cert.email is required for the same reason — it used to default to
  # admin@<dns.domain>, a mailbox the toolkit invented and nobody necessarily
  # reads, so CA expiry and revocation notices could arrive nowhere.
  acme_email  = try(local.config.cert.email, "")
  acme_server = try(local.config.cert.server, "")

  # The ACME account key caches the *registered account*, not just a keypair.
  # Keeping one name across CAs makes cert-manager reuse the old account and
  # silently ignore the new server and EAB, so the name tracks the directory URL.
  acme_account_key_secret = "acme-account-key-${substr(sha256(local.acme_server), 0, 8)}"

  # --- email (transactional SMTP) ------------------------------------------
  smtp_host  = try(local.config.email.host, "")
  smtp_port  = tostring(try(local.config.email.port, "587"))
  email_from = try(local.config.email.from, "noreply@${local.config.dns.domain}")

  # --- alerting (delivery channels) ----------------------------------------
  alert_email_to   = try(local.config.alerting.email.to, "alerts@example.invalid")
  telegram_chat_id = tostring(try(local.config.alerting.telegram.chat_id, "0"))

  # --- data (per-store mode) -----------------------------------------------
  # in-cluster-managed: operators + CRs deployed, endpoints derived.
  # external-unmanaged: adopter-supplied endpoint/credentials, hub-data slice suppressed.
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

  flux_version = try(local.cluster.flux.version, "2.9.3")
}

# Cross-field validation that JSON Schema cannot express.
resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = try(local.config.version, 0) == 1
      error_message = "config.yaml must declare 'version: 1' (schema version)."
    }
    precondition {
      condition     = local.acme_server != ""
      error_message = "cert.server is required — it is the ACME directory URL, and it alone selects the certificate authority. Use https://acme-v02.api.letsencrypt.org/directory for Let's Encrypt; any other CA also needs ACME_EAB_KEY_ID and ACME_EAB_HMAC_ENCODED in .env."
    }
    precondition {
      condition     = contains(["tooling", "hub", "bare"], local.cluster_role)
      error_message = "cluster.role must be one of: tooling, hub, bare."
    }
    precondition {
      condition     = local.cluster_name != ""
      error_message = "cluster.name resolved to an empty string — set it, or name the environment directory."
    }
    precondition {
      condition     = local.acme_email != ""
      error_message = "cert.email is required — it is the ACME account contact the CA sends expiry and revocation notices to. It is no longer defaulted to admin@<dns.domain>, because that named a mailbox nobody necessarily reads."
    }
    # Endpoints are stated, never derived, so 'enabled with nothing to point at'
    # is the failure these three catch — at plan time, rather than midway
    # through a Flux reconcile.
    precondition {
      condition     = !local.registry_active || local.registry_url != ""
      error_message = "registry.enabled is true but registry.url is not set. State the mirror URL outright (no oci:// prefix), or set registry.enabled to false."
    }
    precondition {
      condition = !local.observability_active || alltrue([
        for u in [local.loki_url, local.mimir_url, local.tempo_url] : u != ""
      ])
      error_message = "observability.enabled is true but loki_url, mimir_url and tempo_url are not all set. State all three outright, or set observability.enabled to false."
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
      condition     = local.cluster_role != "hub" || contains(["fspiop", "iso20022"], local.api_type)
      error_message = "app.api_type must be fspiop or iso20022."
    }

    # The pools are the cluster's entire LB address supply; without them no
    # gateway gets an address on a self-managed cluster.
    precondition {
      condition     = !local.is_talos_provider || length(local.lb_ipam_pools) > 0
      error_message = "infra.provider '${local.provider_name}' is on-prem — cluster.lb_ipam.pools is required."
    }
    precondition {
      condition = length(local.lb_ipam_pools) == 0 || (
        local.cluster_role == "hub"
        ? alltrue([for k in local.hub_only_pools : contains(keys(local.lb_ipam_pools), k)])
        : alltrue([for k in local.hub_only_pools : !contains(keys(local.lb_ipam_pools), k)])
      )
      error_message = "lb_ipam.pools: gw-extapi and gw-intapi are required on role 'hub' and rejected on other roles — only a hub serves the FSPIOP endpoints."
    }
    precondition {
      condition = length(distinct(concat(
        [for p in values(local.lb_ipam_pools) : p.lan],
        [tostring(try(local.cluster.vip, ""))],
      ))) == length(local.lb_ipam_pools) + 1
      error_message = "lb_ipam.pools lan addresses must be distinct from each other and from cluster.vip."
    }
    precondition {
      condition = length(distinct([
        for p in values(local.lb_ipam_pools) : p.wan if p.wan != ""
      ])) == length([for p in values(local.lb_ipam_pools) : p.wan if p.wan != ""])
      error_message = "lb_ipam.pools wan addresses must be unique — two gateways cannot share one outside IP on :443."
    }

    # The in-cluster data layer is only packaged for Talos providers. Without
    # this, a managed-Kubernetes hub reconciles green while cluster-config
    # advertises in-cluster hostnames that were never deployed, and every app
    # pod CrashLoops on DNS.
    precondition {
      condition = (
        local.cluster_role != "hub" || local.is_talos_provider ||
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
      error_message = "template '${local.config.template}' references placement groups that ${var.env_dir}/placement.yaml does not map: ${join(", ", setsubtract(local.template_placement_groups, keys(local.placement_map)))}."
    }

    # Matched versions only: an environment declaring dtk_version pins the DTK
    # release it was written against; the clone's actual tag must equal it. A
    # mismatch fails — it never warns — because env repos and the clone version
    # independently and this assert is what holds the model together.
    precondition {
      condition     = try(local.config.dtk_version, "") == "" || try(local.config.dtk_version, "") == var.dtk_tag
      error_message = "config.yaml declares dtk_version '${try(local.config.dtk_version, "")}' but the clone is at '${var.dtk_tag != "" ? var.dtk_tag : "(no exact tag)"}'. Check out the matching DTK tag or update dtk_version."
    }

    # Node labels derive mechanically from pool names, so nothing may declare
    # them by hand — a workload class carrying node_labels/node_taints is the
    # old drift-prone pattern reintroduced.
    precondition {
      condition = alltrue([
        for name, class in try(local.workload_classes.classes, {}) :
        !can(class.node_labels) && !can(class.node_taints)
      ])
      error_message = "workload-classes.yaml declares node_labels/node_taints on a class. Labels derive from pool names; taints are declared by the pool in placement.yaml."
    }

    # An environment-added pool (a name the template does not define) must
    # carry the full pool shape, or node expansion fails cryptically later.
    precondition {
      condition = alltrue([
        for name, o in local.env_pool_overrides :
        contains(keys(local.template_pools), name) || !try(o.enabled, true) || alltrue([
          for k in ["class", "count", "cores", "memory", "disks"] : can(o[k])
        ])
      ])
      error_message = "placement.yaml pools defines a pool the template does not have without the full shape (class, count, cores, memory, disks are all required for new pools)."
    }

    # Node group names become VM name suffixes and for_each keys.
    precondition {
      condition     = length(local.node_groups) == length(distinct([for g in local.node_groups : g.name]))
      error_message = "template '${local.config.template}' has duplicate node_group names."
    }

    # An enabled backup target must carry every parameter it signs with. bucket
    # and region are checked alongside the endpoint because neither is defaulted
    # any more: an unset bucket used to become 'backups' and an unset region
    # 'us-east-1', both of which fail at backup time rather than here.
    precondition {
      condition = !local.object_storage_active || alltrue([
        for v in [local.backup_s3_endpoint, local.backup_s3_bucket, local.backup_s3_region] : v != ""
      ])
      error_message = "object_storage.enabled is true but endpoint, bucket and region are not all set. State all three outright, or set object_storage.enabled to false."
    }
    precondition {
      condition     = length(local.object_storage_buckets) == 0 || local.cluster_role == "tooling"
      error_message = "object_storage.buckets declares buckets to serve and is only valid on cluster.role 'tooling'; hub clusters consume one via object_storage.bucket."
    }
    precondition {
      condition = alltrue([
        for b in local.object_storage_buckets :
        can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b))
      ])
      error_message = "object_storage.buckets names must be valid S3 bucket names (3-63 chars, lowercase alphanumeric, '.' or '-')."
    }
    precondition {
      condition = alltrue([
        for b in local.object_storage_buckets :
        !contains(local.minio_system_buckets, b)
      ])
      error_message = "object_storage.buckets must not re-declare a system bucket (${join(", ", local.minio_system_buckets)}) — those always exist."
    }
    precondition {
      condition     = length(local.object_storage_buckets) == length(distinct(local.object_storage_buckets))
      error_message = "object_storage.buckets contains duplicate names."
    }
    precondition {
      condition     = length(local.registry_robots) == 0 || local.cluster_role == "tooling"
      error_message = "registry.robots declares robot accounts to provision and is only valid on cluster.role 'tooling'; hub clusters consume one via OCI_PROXY_USERNAME/PASSWORD in .env."
    }
    precondition {
      condition = alltrue([
        for r in local.registry_robots :
        can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", r))
      ])
      error_message = "registry.robots names must be lowercase alphanumeric with '.', '_' or '-' separators."
    }
    precondition {
      condition     = length(local.registry_robots) == length(distinct(local.registry_robots))
      error_message = "registry.robots contains duplicate names."
    }
    precondition {
      condition     = length(local.observability_ingest_users) == 0 || local.cluster_role == "tooling"
      error_message = "observability.ingest_users declares telemetry-ingest accounts to provision and is only valid on cluster.role 'tooling'; hub clusters consume one via OBS_INGEST_USERNAME/PASSWORD in .env."
    }
    precondition {
      condition = alltrue([
        for u in local.observability_ingest_users :
        can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", u))
      ])
      error_message = "observability.ingest_users names must be lowercase alphanumeric with '.', '_' or '-' separators."
    }
    precondition {
      condition     = length(local.observability_ingest_users) == length(distinct(local.observability_ingest_users))
      error_message = "observability.ingest_users contains duplicate names."
    }
  }
}
