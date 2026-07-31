# Flux Config Module (config stack)
# Creates the in-cluster configuration Flux consumes:
#   cluster-config ConfigMap + cluster-secrets Secret (postBuild substitution),
#   per-chart values-override ConfigMaps, OCIRepository, and all Kustomizations.
#
# Kustomization graph (Flux dependsOn, role-gated):
#   platform -> dns/<provider> -> platform-config -> <vendor> -> <role>
#   cc:  cc -> cc-config -> {cc-routes, cc-observability -> cc-observability-routes}
#   env: env -> env-data-common -> env-data-<store>... -> env-auth -> env-auth-config -> env-app
#        env-observability-agent (parallel, after platform-config)

locals {
  s = var.secrets

  # The Makefile emits every known credential key, using "" for unset ones, so
  # an absent value arrives as an empty string rather than a missing key —
  # lookup()'s default never fires. Drop the empties first so defaults work.
  set_secrets = { for k, v in var.secrets : k => v if v != "" }

  has_oci_credentials = lookup(local.s, "OCI_REPO_USERNAME", "") != "" && lookup(local.s, "OCI_REPO_PASSWORD", "") != ""
  is_talos            = contains(["proxmox", "openstack"], var.infra_provider)
  has_vendor          = contains(["proxmox", "openstack", "aws", "gcp"], var.infra_provider)
  is_env              = var.cluster_role == "env"
  is_cc               = var.cluster_role == "cc"
  vendor_name         = local.is_talos ? "talos" : var.infra_provider

  # Extract registry host from artifact URL ("oci://ghcr.io/x/y" -> "ghcr.io")
  oci_registry = local.has_oci_credentials ? split("/", replace(var.artifact_url, "oci://", ""))[0] : ""

  dockerconfigjson = local.has_oci_credentials ? jsonencode({
    auths = {
      (local.oci_registry) = {
        username = local.s["OCI_REPO_USERNAME"]
        password = local.s["OCI_REPO_PASSWORD"]
        auth     = base64encode("${local.s["OCI_REPO_USERNAME"]}:${local.s["OCI_REPO_PASSWORD"]}")
      }
    }
  }) : ""

  # DNS provider credentials for gitops/dns/<provider> substitution
  dns_credentials = {
    digitalocean_token       = lookup(local.s, "DIGITALOCEAN_TOKEN", "")
    cloudflare_api_token     = lookup(local.s, "CLOUDFLARE_API_TOKEN", "")
    aws_access_key_id        = lookup(local.s, "AWS_ACCESS_KEY_ID", "")
    aws_secret_access_key    = lookup(local.s, "AWS_SECRET_ACCESS_KEY", "")
    aws_region               = lookup(local.s, "AWS_REGION", "")
    powerdns_api_url         = lookup(local.s, "POWERDNS_API_URL", "")
    powerdns_api_key         = lookup(local.s, "POWERDNS_API_KEY", "")
    dns_provider_credentials = "${lookup(local.s, "DIGITALOCEAN_TOKEN", "")}${lookup(local.s, "CLOUDFLARE_API_TOKEN", "")}${lookup(local.s, "AWS_ACCESS_KEY_ID", "")}${lookup(local.s, "POWERDNS_API_KEY", "")}"
  }

  # ---------------------------------------------------------------------------
  # Generated internal service passwords.
  # A matching non-empty UPPER_CASE key in var.secrets overrides generation
  # (used by external-unmanaged data stores and for migrating existing envs).
  # ---------------------------------------------------------------------------
  # Declared buckets (cc only) each get a scoped MinIO user whose secret key
  # follows the generated-secret pattern: minio_bucket_<name>_secret_key,
  # overridable via the matching UPPER_CASE key in .env.
  minio_declared_buckets = local.is_cc ? var.object_storage.buckets : []
  # Mirrors the default buckets list in gitops/cc-config/minio/minio-values.yaml.
  minio_system_buckets = ["harbor", "backups", "thanos", "loki", "tempo"]
  minio_bucket_secret_names = {
    for b in local.minio_declared_buckets :
    b => "minio_bucket_${replace(replace(b, "-", "_"), ".", "_")}_secret_key"
  }

  # Declared robot accounts (cc only) each get a pull-only Harbor robot whose
  # secret follows the same pattern: harbor_robot_<name>_secret, overridable
  # via the matching UPPER_CASE key in .env.
  harbor_declared_robots = local.is_cc ? var.registry.robots : []
  harbor_robot_secret_names = {
    for r in local.harbor_declared_robots :
    r => "harbor_robot_${replace(replace(r, "-", "_"), ".", "_")}_secret"
  }

  generated_secret_names = setunion(
    local.is_cc ? [
      "minio_root_password",
      "harbor_admin_password",
      "grafana_admin_password",
    ] : [],
    values(local.minio_bucket_secret_names),
    local.is_env ? [
      "mysql_root_password",
      "mysql_central_ledger_password",
      "mysql_account_lookup_password",
      "mysql_oracle_msisdn_password",
      "mongodb_root_password",
      "mongodb_app_password",
      "kratos_db_password",
      "keto_db_password",
      "hydra_db_password",
      "mcm_db_password",
      "hub_admin_password",
      "mcm_oidc_client_secret",
      "role_assign_svc_secret",
      "kratos_secrets_cipher",
      "kratos_secrets_cookie",
      "kratos_secrets_csrf_cookie",
      "kratos_secrets_default",
      "hydra_secrets_system",
      "hydra_secrets_cookie",
    ] : [],
  )

  generated_secrets = merge(
    {
      for name in local.generated_secret_names :
      name => (
        lookup(local.s, upper(name), "") != ""
        ? local.s[upper(name)]
        : random_password.generated[name].result
      )
    },
    {
      for r, name in local.harbor_robot_secret_names :
      name => (
        lookup(local.s, upper(name), "") != ""
        ? local.s[upper(name)]
        : random_password.harbor_robot[name].result
      )
    },
  )

  # Provisioning payload for the Harbor setup Job: [{name, secret}, ...].
  harbor_robots = [
    for r, name in local.harbor_robot_secret_names :
    { name = r, secret = local.generated_secrets[name] }
  ]
}

resource "random_password" "generated" {
  for_each = local.generated_secret_names

  length = 32
  # Alphanumeric only: these values travel through YAML substitution, DSN
  # strings, and shell-quoted seeds — special characters break too many layers.
  special = false
}

# Separate resource, not extra min_* arguments on "generated": changing any
# parameter there would force-replace and silently rotate every generated
# secret on existing environments.
resource "random_password" "harbor_robot" {
  for_each = toset(values(local.harbor_robot_secret_names))

  length  = 32
  special = false
  # Harbor rejects robot secrets lacking an uppercase, lowercase, and digit.
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# ---------------------------------------------------------------------------
# cluster-config — non-secret substitution variables
# ---------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = var.flux_namespace
  }

  data = merge(
    {
      cluster_name       = var.cluster_name
      domain             = var.domain
      gateway_class_name = var.gateway_class_name
      lb_ipam_start      = split("-", var.lb_ipam_range)[0]
      lb_ipam_stop       = split("-", var.lb_ipam_range)[1]

      # cert capability (ACME)
      acme_email  = var.cert.acme_email
      acme_server = var.cert.acme_server

      # email + alerting capabilities (non-secret halves)
      smtp_host        = var.email.host
      smtp_port        = var.email.port
      alert_email_from = var.email.from
      alert_email_to   = var.alerting.email_to
      telegram_chat_id = var.alerting.telegram_chat_id

      # observability sink
      loki_url  = var.observability.loki_url
      mimir_url = var.observability.mimir_url
      tempo_url = var.observability.tempo_url
    },
    local.is_env ? {
      mysql_host   = var.data_stores["mysql"].host
      mysql_port   = var.data_stores["mysql"].port
      kafka_host   = var.data_stores["kafka"].host
      kafka_port   = var.data_stores["kafka"].port
      mongodb_host = var.data_stores["mongodb"].host
      mongodb_port = var.data_stores["mongodb"].port
      redis_host   = var.data_stores["redis"].host
      redis_port   = var.data_stores["redis"].port

      hub_participant_name     = var.app.hub_participant_name
      hub_admin_email          = var.app.hub_admin_email
      onboarding_funds_in      = var.app.onboarding_funds_in
      onboarding_net_debit_cap = var.app.onboarding_net_debit_cap
      api_type                 = var.app.api_type

      backup_s3_endpoint = var.object_storage.endpoint
      backup_s3_bucket   = var.object_storage.bucket
      backup_s3_region   = var.object_storage.region
    } : {},
    var.profile_vars,
  )
}

# ---------------------------------------------------------------------------
# cluster-secrets — secret substitution variables
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = merge(
    local.dns_credentials,
    {
      oci_repo_username = lookup(local.s, "OCI_REPO_USERNAME", "")
      oci_repo_password = lookup(local.s, "OCI_REPO_PASSWORD", "")
      smtp_user         = lookup(local.s, "SMTP_USER", "")
      smtp_password     = lookup(local.s, "SMTP_PASSWORD", "")
      # Grafana Telegram contact point tolerates a dummy token; empty breaks provisioning
      telegram_bot_token = lookup(local.set_secrets, "TELEGRAM_BOT_TOKEN", "unset")
    },
    local.is_cc ? {
      minio_root_user        = lookup(local.set_secrets, "MINIO_ROOT_USER", "minioadmin")
      minio_root_password    = local.generated_secrets["minio_root_password"]
      harbor_admin_password  = local.generated_secrets["harbor_admin_password"]
      grafana_admin_password = local.generated_secrets["grafana_admin_password"]
      # Robot payload for the Harbor setup Job. base64 because it is
      # substituted into the data: field of a Secret manifest — quoting-proof
      # for JSON content. Always present ("W10=" = []) so substitution and the
      # Job's mount never fail on a CC with no robots declared.
      harbor_robots_json = base64encode(jsonencode(local.harbor_robots))
      # Substituted into the Job's pod-template annotations: any robot or
      # secret change alters the Job spec, and the force annotation on the Job
      # lets Flux recreate (= re-run) it.
      harbor_robots_hash = sha256(jsonencode(local.harbor_robots))
    } : {},
    local.is_env ? {
      mysql_root_password           = local.generated_secrets["mysql_root_password"]
      mysql_central_ledger_password = local.generated_secrets["mysql_central_ledger_password"]
      mysql_account_lookup_password = local.generated_secrets["mysql_account_lookup_password"]
      mysql_oracle_msisdn_password  = local.generated_secrets["mysql_oracle_msisdn_password"]
      mongodb_root_password         = local.generated_secrets["mongodb_root_password"]
      mongodb_app_password          = local.generated_secrets["mongodb_app_password"]
      kratos_db_password            = local.generated_secrets["kratos_db_password"]
      keto_db_password              = local.generated_secrets["keto_db_password"]
      hydra_db_password             = local.generated_secrets["hydra_db_password"]
      mcm_db_password               = local.generated_secrets["mcm_db_password"]
      hub_admin_password            = local.generated_secrets["hub_admin_password"]
      mcm_oidc_client_secret        = local.generated_secrets["mcm_oidc_client_secret"]
      role_assign_svc_secret        = local.generated_secrets["role_assign_svc_secret"]
      kratos_secrets_cipher         = local.generated_secrets["kratos_secrets_cipher"]
      kratos_secrets_cookie         = local.generated_secrets["kratos_secrets_cookie"]
      kratos_secrets_csrf_cookie    = local.generated_secrets["kratos_secrets_csrf_cookie"]
      kratos_secrets_default        = local.generated_secrets["kratos_secrets_default"]
      hydra_secrets_system          = local.generated_secrets["hydra_secrets_system"]
      hydra_secrets_cookie          = local.generated_secrets["hydra_secrets_cookie"]
      backup_s3_access_key          = lookup(local.s, "BACKUP_S3_ACCESS_KEY", "")
      backup_s3_secret_key          = lookup(local.s, "BACKUP_S3_SECRET_KEY", "")
    } : {}
  )

  type = "Opaque"
}

# minio-buckets-values — buckets declared in object_storage.buckets plus the
# scoped user and per-bucket policy for each. Delivered as a Secret (not a
# ConfigMap) because the users[] entries carry generated secret keys. Helm
# list-merge replaces lists wholesale, so the buckets list re-states the
# system buckets from gitops/cc-config/minio/minio-values.yaml.
resource "kubernetes_secret_v1" "minio_buckets_values" {
  count = length(local.minio_declared_buckets) > 0 ? 1 : 0

  metadata {
    name      = "minio-buckets-values"
    namespace = var.flux_namespace
  }

  data = {
    "values.yaml" = yamlencode({
      buckets = [
        for b in concat(local.minio_system_buckets, local.minio_declared_buckets) :
        { name = b, policy = "none", purge = false }
      ]
      policies = [
        for b in local.minio_declared_buckets : {
          name = "${b}-rw"
          statements = [
            {
              resources = ["arn:aws:s3:::${b}"]
              actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
            },
            {
              resources = ["arn:aws:s3:::${b}/*"]
              actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
            },
          ]
        }
      ]
      users = [
        for b in local.minio_declared_buckets : {
          accessKey = b
          secretKey = local.generated_secrets[local.minio_bucket_secret_names[b]]
          policy    = "${b}-rw"
        }
      ]
    })
  }

  type = "Opaque"
}

# Deployer Helm value overrides — one ConfigMap per values/<chart>.yaml file.
# Referenced by every HelmRelease via valuesFrom (optional: true).
resource "kubernetes_config_map_v1" "helm_value_overrides" {
  for_each = { for k, v in var.helm_value_overrides : k => v if v != "" }

  metadata {
    name      = "${each.key}-values-override"
    namespace = var.flux_namespace
  }

  data = {
    "values.yaml" = each.value
  }
}

# OCI registry credentials (Flux source-controller pull auth)
resource "kubernetes_secret_v1" "oci_credentials" {
  count = local.has_oci_credentials ? 1 : 0

  metadata {
    name      = "oci-credentials"
    namespace = var.flux_namespace
  }

  data = {
    ".dockerconfigjson" = local.dockerconfigjson
  }

  type = "kubernetes.io/dockerconfigjson"
}

# OCIRepository source — single artifact containing all gitops paths
resource "kubectl_manifest" "oci_repository" {
  yaml_body = yamlencode({
    apiVersion = "source.toolkit.fluxcd.io/v1"
    kind       = "OCIRepository"
    metadata = {
      name      = "ml-gitops"
      namespace = var.flux_namespace
    }
    spec = merge(
      {
        interval = "10m"
        url      = var.artifact_url
        ref = {
          tag = var.artifact_version
        }
      },
      local.has_oci_credentials ? {
        secretRef = {
          name = kubernetes_secret_v1.oci_credentials[0].metadata[0].name
        }
      } : {}
    )
  })

  depends_on = [kubernetes_secret_v1.oci_credentials]
}

# ---------------------------------------------------------------------------
# Kustomization graph.
# Every entry is normalized to the same object shape (Terraform requires
# homogeneous types across conditional branches), then filtered on `enabled`.
# Ordering between Kustomizations is Flux's job (dependsOn), not Terraform's.
# ---------------------------------------------------------------------------
locals {
  # env-data: one Kustomization per in-cluster store + a common slice.
  in_cluster_stores = local.is_env && local.is_talos ? sort([
    for store, cfg in var.data_stores : store if cfg.in_cluster
  ]) : []

  store_health = {
    mysql = {
      health_check_exprs = [{
        apiVersion = "pxc.percona.com/v1"
        kind       = "PerconaXtraDBCluster"
        inProgress = "!has(status.state) || status.state == 'initializing'"
        current    = "has(status.state) && status.state == 'ready'"
        failed     = "has(status.state) && status.state == 'error'"
      }]
      health_checks = []
    }
    kafka = {
      health_check_exprs = []
      health_checks = [{
        apiVersion = "kafka.strimzi.io/v1beta2"
        kind       = "Kafka"
        name       = "mojaloop-kafka"
        namespace  = "data"
      }]
    }
    mongodb = {
      health_check_exprs = []
      health_checks = [{
        apiVersion = "psmdb.percona.com/v1"
        kind       = "PerconaServerMongoDB"
        name       = "bulk-mongodb"
        namespace  = "data"
      }]
    }
    redis = {
      health_check_exprs = []
      health_checks      = []
    }
  }

  # Auth needs MySQL (Ory/MCM databases); apps additionally need every other store.
  auth_depends = contains(local.in_cluster_stores, "mysql") ? ["env-data-mysql"] : ["env"]
  app_depends = concat(
    ["env-auth-config"],
    [for store in local.in_cluster_stores : "env-data-${store}" if store != "mysql"],
  )

  # Per-store Kustomizations (always same shape; enabled drives inclusion)
  data_kustomizations = merge(
    {
      "env-data-common" = {
        enabled            = length(local.in_cluster_stores) > 0
        path               = "./env-data/common"
        depends_on         = ["env"]
        timeout            = "5m"
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
    },
    {
      for store, cfg in var.data_stores :
      "env-data-${store}" => {
        enabled            = contains(local.in_cluster_stores, store)
        path               = "./env-data/${store}"
        depends_on         = ["env-data-common"]
        timeout            = "20m"
        wait               = false
        health_checks      = local.store_health[store].health_checks
        health_check_exprs = local.store_health[store].health_check_exprs
      }
    },
  )

  # object_storage 'none' — switch the backup machinery off structurally.
  # postBuild substitution can only swap scalars inside manifests; removing
  # the PXC schedule or flipping booleans needs kustomize patches, attached
  # here to the Kustomizations that own each consumer. PSMDB >=1.22 gates
  # cluster readiness AND app-user creation on PBM reaching its storage, so
  # shipping a backup config without a reachable endpoint deadlocks env-app.
  backup_disabled_patches = {
    for k, v in {
      "env-data-mongodb" = [{
        patch = yamlencode({
          apiVersion = "psmdb.percona.com/v1"
          kind       = "PerconaServerMongoDB"
          metadata   = { name = "bulk-mongodb", namespace = "data" }
          spec       = { backup = { enabled = false, pitr = { enabled = false } } }
        })
        target = {
          group   = "psmdb.percona.com"
          version = "v1"
          kind    = "PerconaServerMongoDB"
          name    = "bulk-mongodb"
        }
      }]
      "env-data-mysql" = [{
        patch = yamlencode([
          { op = "remove", path = "/spec/backup/schedule" },
          { op = "replace", path = "/spec/backup/pitr/enabled", value = false },
        ])
        target = {
          group   = "pxc.percona.com"
          version = "v1"
          kind    = "PerconaXtraDBCluster"
          name    = "mojaloop-db"
        }
      }]
      "env-auth" = [{
        patch = yamlencode({
          apiVersion = "batch/v1"
          kind       = "CronJob"
          metadata   = { name = "vault-raft-snapshot", namespace = "vault" }
          spec       = { suspend = true }
        })
        target = {
          group   = "batch"
          version = "v1"
          kind    = "CronJob"
          name    = "vault-raft-snapshot"
        }
      }]
    } : k => v if !var.object_storage.active
  }

  all_kustomizations = merge(
    {
      "platform" = {
        enabled    = true
        path       = "./platform"
        depends_on = []
        timeout    = ""
        wait       = false
        health_checks = [
          { apiVersion = "apps/v1", kind = "Deployment", name = "external-secrets-external-secrets-webhook", namespace = "external-secrets" },
          { apiVersion = "apps/v1", kind = "Deployment", name = "cert-manager-cert-manager-webhook", namespace = "cert-manager" },
        ]
        health_check_exprs = []
      }
      "dns" = {
        enabled            = true
        path               = "./dns/${var.dns_provider}"
        depends_on         = ["platform"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      "platform-config" = {
        enabled            = true
        path               = "./platform-config"
        depends_on         = ["dns"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      # vendor (infra-provider gap fillers) — name varies by provider
      (local.vendor_name) = {
        enabled            = local.has_vendor
        path               = "./${local.vendor_name}"
        depends_on         = ["platform-config"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      # role chain entry (cc or env); "base" gets no role kustomization
      (var.cluster_role) = {
        enabled    = var.cluster_role != "base"
        path       = "./${var.cluster_role}"
        depends_on = [local.has_vendor ? local.vendor_name : "platform-config"]
        timeout    = local.is_env ? "10m" : "5m"
        wait       = false
        health_checks = local.is_env ? [
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "psmdb-operator", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "pxc-operator", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "strimzi-kafka-operator", namespace = var.flux_namespace },
        ] : []
        health_check_exprs = []
      }
      # --- cc chain ---
      "cc-config" = {
        enabled    = local.is_cc
        path       = "./cc-config"
        depends_on = ["cc"]
        timeout    = "20m"
        wait       = false
        health_checks = [
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "minio", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "harbor", namespace = var.flux_namespace },
        ]
        health_check_exprs = []
      }
      "cc-routes" = {
        enabled            = local.is_cc
        path               = "./cc-routes"
        depends_on         = ["cc-config"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      "cc-observability" = {
        enabled    = local.is_cc
        path       = "./cc-observability"
        depends_on = ["cc-config"]
        timeout    = "20m"
        wait       = false
        health_checks = [
          { apiVersion = "apps/v1", kind = "StatefulSet", name = "thanos-receive", namespace = "observability" },
          { apiVersion = "apps/v1", kind = "Deployment", name = "thanos-query", namespace = "observability" },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "loki", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "tempo", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "grafana", namespace = var.flux_namespace },
        ]
        health_check_exprs = []
      }
      "cc-observability-routes" = {
        enabled            = local.is_cc
        path               = "./cc-observability-routes"
        depends_on         = ["cc-observability"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      # --- env chain ---
      "env-auth" = {
        enabled    = local.is_env
        path       = "./env-auth"
        depends_on = local.auth_depends
        timeout    = "20m"
        wait       = false
        health_checks = [
          { apiVersion = "vault.banzaicloud.com/v1alpha1", kind = "Vault", name = "vault", namespace = "vault" },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "kratos", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "keto", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "hydra", namespace = var.flux_namespace },
        ]
        health_check_exprs = []
      }
      "env-auth-config" = {
        enabled            = local.is_env
        path               = "./env-auth-config"
        depends_on         = ["env-auth"]
        timeout            = "10m"
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      "env-app" = {
        enabled    = local.is_env
        path       = "./env-app"
        depends_on = local.app_depends
        timeout    = "30m"
        wait       = false
        health_checks = [
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "mojaloop", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "mcm", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "finance-portal", namespace = var.flux_namespace },
        ]
        health_check_exprs = []
      }
      "env-observability-agent" = {
        enabled            = local.is_env
        path               = "./env-observability-agent"
        depends_on         = ["platform-config"]
        timeout            = "5m"
        wait               = true
        health_checks      = []
        health_check_exprs = []
      }
    },
    local.data_kustomizations,
  )

  kustomizations = { for k, v in local.all_kustomizations : k => v if v.enabled }
}

resource "kubectl_manifest" "kustomization" {
  for_each = local.kustomizations

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = each.key
      namespace = var.flux_namespace
    }
    spec = merge(
      {
        interval = "10m"
        path     = each.value.path
        prune    = true
        sourceRef = {
          kind = "OCIRepository"
          name = "ml-gitops"
        }
        postBuild = {
          substituteFrom = [
            { kind = "ConfigMap", name = kubernetes_config_map_v1.cluster_config.metadata[0].name },
            { kind = "Secret", name = kubernetes_secret_v1.cluster_secrets.metadata[0].name },
          ]
        }
      },
      length(each.value.depends_on) > 0 ? {
        dependsOn = [for d in each.value.depends_on : { name = d }]
      } : {},
      each.value.timeout != "" ? { timeout = each.value.timeout } : {},
      each.value.wait ? { wait = true } : {},
      length(each.value.health_checks) > 0 ? {
        healthChecks = each.value.health_checks
      } : {},
      length(each.value.health_check_exprs) > 0 ? {
        healthCheckExprs = each.value.health_check_exprs
      } : {},
      length(lookup(local.backup_disabled_patches, each.key, [])) > 0 ? {
        patches = local.backup_disabled_patches[each.key]
      } : {},
    )
  })

  depends_on = [
    kubectl_manifest.oci_repository,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets,
  ]
}
