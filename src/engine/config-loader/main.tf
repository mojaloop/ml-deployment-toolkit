# Config Loader Module
# Loads and resolves the environment configuration:
#   <env>/config.yaml                 (adopter-authored, schema-validated)
#   <env>/placement.yaml              (adopter-authored, node placement facts)
#   <env>/proxmox/proxmox.yaml        (adopter-authored, provider infra facts)
#   providers/<provider>/templates/<role>/<template>/  (full-overlay template directory)
#   providers/<provider>/params.yaml  (provider interface + infra config)
#   config/definitions/workload-classes.yaml  (platform definitions)
# Expands node groups into provider shapes and resolves capability bindings
# (registry, object_storage, observability, cert, email, alerting, data modes).

locals {
  # --- Raw inputs ---------------------------------------------------------
  config           = yamldecode(file(var.config_path))
  workload_classes = yamldecode(file(var.workload_classes_path))
  # The provider contract version (L1 platform definition, sibling of
  # workload-classes.yaml). Every provider package declares the contract
  # version it implements; equality is asserted below — plainly, like
  # dtk_version, never as a compatibility matrix.
  provider_contract = yamldecode(file("${dirname(var.workload_classes_path)}/provider-contract.yaml"))

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
  provider_params_file = yamldecode(file("${var.providers_path}/${local.provider_name}/params.yaml"))
  provider_params      = try(local.provider_params_file.params, {})
  mapping              = try(local.provider_params_file.infra, {})

  # Structural capabilities the provider declares (params.schema.json requires
  # every capability stated explicitly). Consumers gate on these, never on
  # provider names: a new provider turns features on by declaring them, not by
  # being added to lists scattered through the codebase. The try() default is
  # unreachable for schema-valid files and exists only so a missing block
  # fails the precondition below by name instead of erroring mid-expression.
  provider_capabilities = try(local.provider_params_file.capabilities, {})
  cap_in_cluster_data   = try(local.provider_capabilities.in_cluster_data, false)

  # Workload-class MATERIALIZATIONS — the provider package's per-class seat
  # (providers/<p>/classes.yaml). Identity stays in workload-classes.yaml;
  # how a class materializes (talos fragments, VM shape, instance type, node
  # OS config) is the provider's business. Completeness is asserted below:
  # every platform class must have an entry.
  provider_classes_file = yamldecode(file("${var.providers_path}/${local.provider_name}/classes.yaml"))
  provider_classes      = local.provider_classes_file.classes

  # A template is a directory — the full overlay for one provider, role and
  # capacity: template.yaml (identity + tuning), placement.yaml (the shape:
  # node pools, default topology), values/ and patches/ (gitops deltas),
  # talos/<pool>.yaml (per-pool machine-config fragments).
  template_dir       = "${var.providers_path}/${local.provider_name}/templates/${local.cluster_role}/${local.config.template}"
  template           = yamldecode(file("${local.template_dir}/template.yaml"))
  template_placement = yamldecode(file("${local.template_dir}/placement.yaml"))

  # --- VM pools: match by name, shallow per-field replacement ---------------
  # Template owns the shape; the environment owns the instance. Environment
  # placement.yaml `pools:` entries match the template pool of the same name;
  # each top-level field the override names REPLACES the template's field
  # wholesale — lists included (overriding taints or disks restates the whole
  # list; nothing is deep-merged). Omitted fields are inherited, so changing
  # count inherits everything else. Unknown names add extra pools, and
  # `enabled: false` drops a default pool — visible in the environment file as
  # a deliberate decision rather than an absence. This shallow merge() IS the
  # declared semantics (see placement.schema.json): list deep-merge is
  # ambiguous for disks/taints, wholesale replacement is legible.
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
  # Stated in the platform definitions file, not defaulted here.
  talos_image_arch = local.workload_classes.talos_image.arch
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
  # Instance types come from the per-class materialization seat
  # (providers/<p>/classes.yaml), no longer from a free-floating
  # infra.instance_types map in params.yaml.
  instance_types = { for name, c in local.provider_classes : name => try(c.instance_type, "") }

  # AWS placement: EKS has no per-instance placement — a managed node group is
  # only constrained by which subnets (= AZs) it may use, and a multi-AZ group
  # is best-effort spread. When the environment's placement.yaml maps the
  # template's placement groups to AZs, each pool materializes as one
  # single-AZ node group per distinct placement entry, honoring the same
  # wrapping rule as the on-prem per-VM expansion (node i takes
  # placement[i % len]). The split is internal: templates and placement.yaml
  # keep their cross-provider shape. Without a placement map the lists are
  # ignored and each pool stays one unpinned group AWS spreads best-effort —
  # the pre-placement behaviour, and the adopter's explicit "don't care".
  aws_placement_active = local.provider_name == "aws" && length(local.placement_map) > 0

  aws_pool_slots = {
    for g in local.node_groups : g.name => [
      for i in range(g.count) :
      local.aws_placement_active && length(try(g.placement, [])) > 0 ? g.placement[i % length(g.placement)] : ""
    ]
  }

  # Only materialized on the aws provider — the class -> instance-type index
  # below is a hard lookup that must not be evaluated against another
  # provider's (empty) instance_types map.
  aws_node_groups = local.provider_name != "aws" ? [] : flatten([
    for g in local.node_groups : [
      for pg, slots in { for s in local.aws_pool_slots[g.name] : s => s... } : {
        # Suffixed by placement group, not AZ: remapping pg -> AZ later moves
        # the subnet without renaming the Terraform address.
        name  = pg != "" ? "${g.name}-${pg}" : g.name
        az    = pg != "" ? lookup(local.placement_map, pg, "") : ""
        class = g.class
        # Direct index, no fallback default: a class the provider does not
        # map must fail the plan (precondition below names it), never
        # silently become some other instance type.
        instance_types = [local.instance_types[g.class]]
        desired_size   = length(slots)
        min_size       = length(slots)
        max_size       = length(slots) + 1
        # Same mechanical derivation as the Talos machine-config patches:
        # <P_NODE_ROLE_LABEL_KEY>=<pool> — the label every gitops selector and
        # soft affinity keys on. Taints come from the pool, exactly like Talos.
        labels = { (local.node_role_label_key) = g.name }
        taints = try(g.taints, [])
        tags   = distinct(concat(["ml"], try(g.tags, [])))
      }
    ]
  ])

  do_node_pools = local.provider_name != "digitalocean" ? [] : [
    for g in local.node_groups : {
      name = g.name
      # Hard lookup — an unmapped class fails the plan (precondition below),
      # never silently becomes a default droplet size.
      size  = local.instance_types[g.class]
      count = g.count
      tags  = distinct(concat(["ml"], try(g.tags, [])))
    }
  ]

  # --- Dynamic label/taint patches per workload class (Talos only) ---------
  # Per-POOL machine-config patch: the node label derives MECHANICALLY from the
  # pool name (<P_NODE_ROLE_LABEL_KEY>=<pool>) — never typed by hand, so the
  # Talos side and the gitops selectors cannot drift. Taints are declared by
  # the pool itself in placement.yaml, once.
  # Direct reference, no fallback: P_NODE_ROLE_LABEL_KEY is schema-required in
  # every provider params.yaml — a try() default here would hide its absence.
  node_role_label_key = local.provider_params.P_NODE_ROLE_LABEL_KEY
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
  # Stated, never derived: host, port and from are schema-required together
  # when the email block exists. port used to default to "587" and from to
  # noreply@<dns.domain> — an invented sender that breaks SPF/DMARC silently.
  # The empty defaults below only exist for environments without the
  # capability (no email block at all).
  smtp_host  = try(local.config.email.host, "")
  smtp_port  = tostring(try(local.config.email.port, ""))
  email_from = try(local.config.email.from, "")

  # --- alerting (delivery channels) ----------------------------------------
  # alerting.email.to used to default to alerts@example.invalid — alerts
  # routed to a mailbox that cannot exist, silently. Now schema-required when
  # the alerting.email block exists; empty means the channel is absent.
  # telegram chat_id "0" is the DISABLED sentinel for an absent telegram
  # block (Grafana provisioning tolerates it, like the "unset" bot token);
  # when the block exists, chat_id is schema-required.
  alert_email_to   = try(local.config.alerting.email.to, "")
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
      # External stores state host AND port outright — the port used to fall
      # back to the store's conventional port, which is exactly the kind of
      # silent default that breaks when an external endpoint is non-standard.
      port = (
        try(local.config.data[store].mode, "in-cluster-managed") == "in-cluster-managed"
        ? defaults.port
        : tostring(try(local.config.data[store].port, ""))
      )
    }
  }

  # --- artifact (distribution gitops source) -------------------------------
  # version is pinned, never "latest" (schema pattern) and never defaulted:
  # a defaulted moving tag is unauditable and contradicts matched-versions-only.
  artifact_url     = try(local.config.artifact.url, "")
  artifact_version = try(local.config.artifact.version, "")
  artifact_active  = try(local.config.artifact.active, local.artifact_url != "")
  # Cosign verification — flag defaults OFF: the distribution's signing
  # infrastructure does not exist yet. Once artifacts are signed, verify: true
  # makes Flux reject unsigned/tampered artifacts (keyless unless
  # verify_secret names a cosign public-key Secret).
  artifact_verify        = try(local.config.artifact.verify, false)
  artifact_verify_secret = try(local.config.artifact.verify_secret, "")

  # --- app / hub parameters -------------------------------------------------
  # Hub parameters are stated, never defaulted, on hub clusters (preconditions
  # below). api_type used to default to fspiop, participant_name to "Hub" and
  # the onboarding amounts to 100000/1000 — financial and protocol facts an
  # adopter must consciously set. Empty defaults exist only so the
  # preconditions can report the missing field by name on hub clusters, and
  # so non-hub roles (which never consume them) resolve cleanly.
  api_type                 = try(local.config.app.api_type, "")
  hub_participant_name     = try(local.config.app.hub.participant_name, "")
  hub_admin_email          = try(local.config.app.hub.admin_email, "")
  onboarding_funds_in      = tostring(try(local.config.app.hub.onboarding.funds_in, ""))
  onboarding_net_debit_cap = tostring(try(local.config.app.hub.onboarding.net_debit_cap, ""))

  # Flux distribution version is a platform definition (single-sourced in
  # workload-classes.yaml beside talos/kubernetes versions), not adopter
  # config — the old cluster.flux.version override was a silent default and
  # is gone from the environment schema.
  flux_version = local.workload_classes.flux_version
}

# Cross-field validation that JSON Schema cannot express.
resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = try(local.config.version, 0) == 1
      error_message = "config.yaml must declare 'version: 1' (schema version)."
    }
    # Contract versioning (design §5): one contract version per DTK release,
    # every package must match — a plain equality assert, like dtk_version.
    precondition {
      condition     = try(local.provider_params_file.contract_version, 0) == local.provider_contract.contract_version
      error_message = "providers/${local.provider_name}/params.yaml declares contract_version '${try(local.provider_params_file.contract_version, "(unset)")}' but this DTK release's provider contract is version '${local.provider_contract.contract_version}' (config/definitions/provider-contract.yaml). The package must implement the release's contract."
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
        cfg.mode == "in-cluster-managed" || (cfg.host != "" && cfg.port != "")
      ])
      error_message = "external-unmanaged data stores must set data.<store>.host AND data.<store>.port. The port is no longer defaulted to the store's conventional port — external endpoints are stated outright."
    }
    precondition {
      condition     = local.cluster_role != "hub" || contains(["fspiop", "iso20022"], local.api_type)
      error_message = "app.api_type must be set on hub clusters: fspiop or iso20022. It is no longer defaulted to fspiop — the API dialect is set once at deploy time and switching mid-flight breaks in-progress transfers, so it must be a conscious choice."
    }
    precondition {
      condition = local.cluster_role != "hub" || alltrue([
        for v in [local.hub_participant_name, local.hub_admin_email, local.onboarding_funds_in, local.onboarding_net_debit_cap] : v != ""
      ])
      error_message = "hub clusters must state app.hub.participant_name, app.hub.admin_email and app.hub.onboarding.{funds_in,net_debit_cap} outright. The old defaults (participant 'Hub', funds_in 100000, net_debit_cap 1000) were financial facts filled in silently."
    }
    precondition {
      condition     = !local.artifact_active || (local.artifact_url != "" && local.artifact_version != "")
      error_message = "artifact.url and artifact.version must both be set when the gitops artifact is active. version is a pinned vX.Y.Z — it is no longer defaulted to 'latest', which is unauditable and contradicts matched-versions-only."
    }
    # The provider package must materialize EVERY class the platform defines
    # (schema-checked repo-wide by check-interface.sh; asserted here for the
    # active provider) — an entry may be empty, but it must exist: a class
    # missing from the seat is exactly what a renamed class looks like.
    precondition {
      condition = alltrue([
        for name, _ in try(local.workload_classes.classes, {}) : contains(keys(local.provider_classes), name)
      ])
      error_message = "providers/${local.provider_name}/classes.yaml does not materialize every workload class: missing ${join(", ", [for name, _ in try(local.workload_classes.classes, {}) : name if !contains(keys(local.provider_classes), name)])}."
    }
    # Every workload class the topology uses must be mapped to an instance
    # shape on cloud providers — a missing entry used to silently become a
    # default instance type.
    precondition {
      condition = !contains(["aws", "digitalocean"], local.provider_name) || alltrue([
        for g in local.node_groups : try(local.instance_types[g.class], "") != ""
      ])
      error_message = "provider '${local.provider_name}' does not map every used workload class to an instance type: missing ${join(", ", [for g in local.node_groups : g.class if try(local.instance_types[g.class], "") == ""])}. Set instance_type in providers/${local.provider_name}/classes.yaml."
    }
    # email and alerting are internally complete when present (schema enforces
    # the same; this reports by name when the schema was bypassed).
    precondition {
      condition     = local.smtp_host == "" || (local.smtp_port != "" && local.email_from != "")
      error_message = "email.host is set but email.port/email.from are not all set. State all three outright — 'from' is no longer invented as noreply@<domain> (breaks SPF/DMARC silently) and the port is no longer assumed 587."
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

    # The in-cluster data layer only exists where the provider declares the
    # capability. Without this, a hub on an undeclared provider reconciles
    # green while cluster-config advertises in-cluster hostnames that were
    # never deployed, and every app pod CrashLoops on DNS.
    precondition {
      condition = (
        local.cluster_role != "hub" || local.cap_in_cluster_data ||
        alltrue([for store, cfg in local.data_stores : !cfg.in_cluster])
      )
      error_message = "infra.provider '${local.provider_name}' does not declare capabilities.in_cluster_data — every data.<store>.mode must be external-unmanaged on this provider."
    }

    # Placement groups referenced by the template must be mapped to real targets;
    # otherwise the provider is handed the literal group name as a node name and
    # fails partway through apply with VMs already created. On AWS the map is
    # optional (no placement.yaml = no AZ pinning), but once an environment
    # maps anything, every group the template references must resolve to an AZ.
    precondition {
      condition = (
        !(local.is_talos_provider || local.aws_placement_active) ||
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

    # Class identity is identity ONLY: talos_type (role identity) and nothing
    # else. Labels derive from pool names; taints are declared by pools;
    # provider-shaped content (talos_patches, instance types, VM knobs)
    # belongs in providers/<p>/classes.yaml — anything extra here is the old
    # drift-prone pattern reintroduced.
    precondition {
      condition = alltrue([
        for name, class in try(local.workload_classes.classes, {}) :
        length(setsubtract(keys(class), ["talos_type"])) == 0
      ])
      error_message = "workload-classes.yaml declares non-identity keys on a class: ${join("; ", [for name, class in try(local.workload_classes.classes, {}) : "${name}: ${join(", ", setsubtract(keys(class), ["talos_type"]))}" if length(setsubtract(keys(class), ["talos_type"])) > 0])}. Class identity carries only talos_type — materializations live in providers/<provider>/classes.yaml."
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
