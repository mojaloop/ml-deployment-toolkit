# Flux Config Module (config stack)
# Creates the in-cluster configuration Flux consumes:
#   cluster-config ConfigMap + cluster-secrets Secret (postBuild substitution,
#   keys UPPER_SNAKE matching the ${UPPER_SNAKE} gitops tokens), per-release
#   values-override ConfigMaps/Secrets, OCIRepository, and all Kustomizations.
#
# Kustomization graph (Flux dependsOn, role-gated):
#   platform -> dns/<provider> -> platform-config -> <vendor> -> <role>
#   tooling: tooling -> tooling-config -> {tooling-routes, tooling-observability -> tooling-observability-routes}
#   hub: hub -> hub-data-common -> hub-data-<store>... -> hub-auth -> hub-auth-config -> hub-app
#        hub-observability-agent (parallel, after platform-config)

locals {
  s = var.secrets

  # The Makefile emits every known credential key, using "" for unset ones, so
  # an absent value arrives as an empty string rather than a missing key —
  # lookup()'s default never fires. Drop the empties first so defaults work.
  set_secrets = { for k, v in var.secrets : k => v if v != "" }

  has_oci_credentials = lookup(local.s, "OCI_REPO_USERNAME", "") != "" && lookup(local.s, "OCI_REPO_PASSWORD", "") != ""

  is_talos    = contains(["proxmox", "openstack"], var.infra_provider)
  has_vendor  = contains(["proxmox", "openstack", "aws", "gcp"], var.infra_provider)
  is_hub      = var.cluster_role == "hub"
  is_tooling  = var.cluster_role == "tooling"
  vendor_name = local.is_talos ? "talos" : var.infra_provider

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

  # DNS provider credentials for gitops/dns/<provider> substitution.
  # AWS_REGION deliberately lives in cluster-config, not here: it is not a
  # credential, and route53's external-dns/clusterissuer values consume it
  # inside ConfigMap-shaped documents — a substituted secret must never land
  # in a ConfigMap (secret-placement check enforces this).
  dns_credentials = {
    DIGITALOCEAN_TOKEN       = lookup(local.s, "DIGITALOCEAN_TOKEN", "")
    CLOUDFLARE_API_TOKEN     = lookup(local.s, "CLOUDFLARE_API_TOKEN", "")
    AWS_ACCESS_KEY_ID        = lookup(local.s, "AWS_ACCESS_KEY_ID", "")
    AWS_SECRET_ACCESS_KEY    = lookup(local.s, "AWS_SECRET_ACCESS_KEY", "")
    POWERDNS_API_URL         = lookup(local.s, "POWERDNS_API_URL", "")
    POWERDNS_API_KEY         = lookup(local.s, "POWERDNS_API_KEY", "")
    DNS_PROVIDER_CREDENTIALS = "${lookup(local.s, "DIGITALOCEAN_TOKEN", "")}${lookup(local.s, "CLOUDFLARE_API_TOKEN", "")}${lookup(local.s, "AWS_ACCESS_KEY_ID", "")}${lookup(local.s, "POWERDNS_API_KEY", "")}"
  }

  # ACME External Account Binding. Presence of the credentials is the switch —
  # there is no toggle in config.yaml, matching how OCI credentials work above.
  # Every public CA except Let's Encrypt (Google Trust Services, ZeroSSL,
  # SSL.com) requires EAB, and its schema is identical for all of them: RFC 8555
  # fixes it at keyID + HMAC key.
  has_eab = lookup(local.s, "ACME_EAB_KEY_ID", "") != "" && lookup(local.s, "ACME_EAB_HMAC_ENCODED", "") != ""

  # EAB credentials for gitops/dns/<provider>/clusterissuer.yaml substitution.
  # Always present (empty when unused) so the Secret manifest still renders —
  # it is inert until the EAB patch below makes the issuer reference it.
  cert_credentials = {
    ACME_EAB_KEY_ID       = lookup(local.s, "ACME_EAB_KEY_ID", "")
    ACME_EAB_HMAC_ENCODED = lookup(local.s, "ACME_EAB_HMAC_ENCODED", "")
  }

  # ---------------------------------------------------------------------------
  # Generated internal service passwords.
  # Canonical names are UPPER_SNAKE — identical to the cluster-secrets data key,
  # the ${TOKEN} in gitops manifests, and the .env variable name. A matching
  # non-empty key in var.secrets overrides generation (used by
  # external-unmanaged data stores and for migrating existing envs).
  # ---------------------------------------------------------------------------
  # Declared buckets (tooling only) each get a scoped MinIO user whose secret key
  # follows the generated-secret pattern: MINIO_BUCKET_<NAME>_SECRET_KEY,
  # overridable via the matching key in .env.
  minio_declared_buckets = local.is_tooling ? var.object_storage.buckets : []
  # Mirrors the default buckets list in gitops/tooling-config/minio/minio-values.yaml.
  minio_system_buckets = ["harbor", "backups", "thanos", "loki", "tempo"]
  minio_bucket_secret_names = {
    for b in local.minio_declared_buckets :
    b => upper("minio_bucket_${replace(replace(b, "-", "_"), ".", "_")}_secret_key")
  }

  # Declared robot accounts (tooling only) each get a pull-only Harbor robot whose
  # secret follows the same pattern: HARBOR_ROBOT_<NAME>_SECRET, overridable
  # via the matching key in .env.
  harbor_declared_robots = local.is_tooling ? var.registry.robots : []
  harbor_robot_secret_names = {
    for r in local.harbor_declared_robots :
    r => upper("harbor_robot_${replace(replace(r, "-", "_"), ".", "_")}_secret")
  }

  generated_secret_names = setunion(
    local.is_tooling ? [
      "MINIO_ROOT_PASSWORD",
      "HARBOR_ADMIN_PASSWORD",
      "GRAFANA_ADMIN_PASSWORD",
    ] : [],
    values(local.minio_bucket_secret_names),
    local.is_hub ? [
      "MYSQL_ROOT_PASSWORD",
      "MYSQL_CENTRAL_LEDGER_PASSWORD",
      "MYSQL_ACCOUNT_LOOKUP_PASSWORD",
      "MYSQL_ORACLE_MSISDN_PASSWORD",
      "MONGODB_ROOT_PASSWORD",
      "MONGODB_APP_PASSWORD",
      "KRATOS_DB_PASSWORD",
      "KETO_DB_PASSWORD",
      "HYDRA_DB_PASSWORD",
      "MCM_DB_PASSWORD",
      "HUB_ADMIN_PASSWORD",
      "MCM_OIDC_CLIENT_SECRET",
      "ROLE_ASSIGN_SVC_SECRET",
      "KRATOS_SECRETS_CIPHER",
      "KRATOS_SECRETS_COOKIE",
      "KRATOS_SECRETS_CSRF_COOKIE",
      "KRATOS_SECRETS_DEFAULT",
      "HYDRA_SECRETS_SYSTEM",
      "HYDRA_SECRETS_COOKIE",
    ] : [],
  )

  # The canonical name IS the .env key, so the override lookup needs no case
  # mapping: a non-empty var.secrets entry under the same name wins.
  generated_secrets = merge(
    {
      for name in local.generated_secret_names :
      name => (
        lookup(local.s, name, "") != ""
        ? local.s[name]
        : random_password.generated[name].result
      )
    },
    {
      for r, name in local.harbor_robot_secret_names :
      name => (
        lookup(local.s, name, "") != ""
        ? local.s[name]
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
# cluster-config — non-secret substitution variables.
# Data keys are UPPER_SNAKE, matching the ${UPPER_SNAKE} tokens in gitops/.
# ---------------------------------------------------------------------------
locals {
  cluster_config_base = merge(
    {
      # The gateway class is a provider interface symbol now: gitops references
      # ${P_GATEWAY_CLASS}, supplied via var.params from the provider's
      # params.yaml — config.yaml can no longer set or shadow it.
      CLUSTER_NAME = var.cluster_name
      DOMAIN       = var.domain
      # Not a credential — consumed inside ConfigMap-shaped route53 documents,
      # so it must resolve from cluster-config, never from cluster-secrets.
      AWS_REGION = nonsensitive(lookup(var.secrets, "AWS_REGION", ""))

      # Per-gateway LB pool addresses. Empty on cloud providers, where the
      # talos layer (and with it every pool manifest) is never applied.
      GW_INT_IP         = try(var.lb_ipam_pools["gw-int"].lan, "")
      GW_INT_DNS_TARGET = try(var.lb_ipam_pools["gw-int"].dns_target, "")
      GW_EXT_IP         = try(var.lb_ipam_pools["gw-ext"].lan, "")
      GW_EXT_DNS_TARGET = try(var.lb_ipam_pools["gw-ext"].dns_target, "")

      # cert capability (ACME)
      ACME_EMAIL              = var.cert.acme_email
      ACME_SERVER             = var.cert.acme_server
      ACME_ACCOUNT_KEY_SECRET = var.cert.acme_account_key_secret

      # email + alerting capabilities (non-secret halves)
      SMTP_HOST        = var.email.host
      SMTP_PORT        = var.email.port
      ALERT_EMAIL_FROM = var.email.from
      ALERT_EMAIL_TO   = var.alerting.email_to
      TELEGRAM_CHAT_ID = var.alerting.telegram_chat_id

      # observability sink
      LOKI_URL  = var.observability.loki_url
      MIMIR_URL = var.observability.mimir_url
      TEMPO_URL = var.observability.tempo_url
    },
    local.is_hub ? {
      GW_EXTAPI_IP         = try(var.lb_ipam_pools["gw-extapi"].lan, "")
      GW_EXTAPI_DNS_TARGET = try(var.lb_ipam_pools["gw-extapi"].dns_target, "")
      GW_INTAPI_IP         = try(var.lb_ipam_pools["gw-intapi"].lan, "")
      GW_INTAPI_DNS_TARGET = try(var.lb_ipam_pools["gw-intapi"].dns_target, "")

      MYSQL_HOST   = var.data_stores["mysql"].host
      MYSQL_PORT   = var.data_stores["mysql"].port
      KAFKA_HOST   = var.data_stores["kafka"].host
      KAFKA_PORT   = var.data_stores["kafka"].port
      MONGODB_HOST = var.data_stores["mongodb"].host
      MONGODB_PORT = var.data_stores["mongodb"].port
      REDIS_HOST   = var.data_stores["redis"].host
      REDIS_PORT   = var.data_stores["redis"].port

      HUB_PARTICIPANT_NAME     = var.app.hub_participant_name
      HUB_ADMIN_EMAIL          = var.app.hub_admin_email
      ONBOARDING_FUNDS_IN      = var.app.onboarding_funds_in
      ONBOARDING_NET_DEBIT_CAP = var.app.onboarding_net_debit_cap
      API_TYPE                 = var.app.api_type

      BACKUP_S3_ENDPOINT = var.object_storage.endpoint
      BACKUP_S3_BUCKET   = var.object_storage.bucket
      BACKUP_S3_REGION   = var.object_storage.region
    } : {},
    { for k, v in var.profile_vars : upper(k) => v },
  )

  # Provider symbols (P_*) may never shadow a config key, and vice versa —
  # merge order would silently pick a winner, so collisions are an error.
  cluster_config_collisions = sort(setintersection(
    toset(keys(local.cluster_config_base)),
    toset(keys(var.params)),
  ))
}

resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = var.flux_namespace
  }

  data = merge(
    local.cluster_config_base,
    var.params,
  )

  lifecycle {
    precondition {
      condition     = length(local.cluster_config_collisions) == 0
      error_message = "params keys collide with cluster-config keys: ${join(", ", local.cluster_config_collisions)}. Rename the provider symbols or the conflicting config keys."
    }
  }
}

# ---------------------------------------------------------------------------
# cluster-secrets — secret substitution variables.
# Data keys are UPPER_SNAKE, matching the ${UPPER_SNAKE} tokens in gitops/.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = merge(
    local.dns_credentials,
    local.cert_credentials,
    {
      OCI_REPO_USERNAME = lookup(local.s, "OCI_REPO_USERNAME", "")
      OCI_REPO_PASSWORD = lookup(local.s, "OCI_REPO_PASSWORD", "")
      SMTP_USER         = lookup(local.s, "SMTP_USER", "")
      SMTP_PASSWORD     = lookup(local.s, "SMTP_PASSWORD", "")
      # Grafana Telegram contact point tolerates a dummy token; empty breaks provisioning
      TELEGRAM_BOT_TOKEN = lookup(local.set_secrets, "TELEGRAM_BOT_TOKEN", "unset")
    },
    local.is_tooling ? {
      MINIO_ROOT_USER        = lookup(local.set_secrets, "MINIO_ROOT_USER", "minioadmin")
      MINIO_ROOT_PASSWORD    = local.generated_secrets["MINIO_ROOT_PASSWORD"]
      HARBOR_ADMIN_PASSWORD  = local.generated_secrets["HARBOR_ADMIN_PASSWORD"]
      GRAFANA_ADMIN_PASSWORD = local.generated_secrets["GRAFANA_ADMIN_PASSWORD"]
      # Robot payload for the Harbor setup Job. base64 because it is
      # substituted into the data: field of a Secret manifest — quoting-proof
      # for JSON content. Always present ("W10=" = []) so substitution and the
      # Job's mount never fail on a Tooling Cluster with no robots declared.
      HARBOR_ROBOTS_JSON = base64encode(jsonencode(local.harbor_robots))
      # Substituted into the Job's pod-template annotations: any robot or
      # secret change alters the Job spec, and the force annotation on the Job
      # lets Flux recreate (= re-run) it.
      HARBOR_ROBOTS_HASH = sha256(jsonencode(local.harbor_robots))
    } : {},
    local.is_hub ? {
      MYSQL_ROOT_PASSWORD           = local.generated_secrets["MYSQL_ROOT_PASSWORD"]
      MYSQL_CENTRAL_LEDGER_PASSWORD = local.generated_secrets["MYSQL_CENTRAL_LEDGER_PASSWORD"]
      MYSQL_ACCOUNT_LOOKUP_PASSWORD = local.generated_secrets["MYSQL_ACCOUNT_LOOKUP_PASSWORD"]
      MYSQL_ORACLE_MSISDN_PASSWORD  = local.generated_secrets["MYSQL_ORACLE_MSISDN_PASSWORD"]
      MONGODB_ROOT_PASSWORD         = local.generated_secrets["MONGODB_ROOT_PASSWORD"]
      MONGODB_APP_PASSWORD          = local.generated_secrets["MONGODB_APP_PASSWORD"]
      KRATOS_DB_PASSWORD            = local.generated_secrets["KRATOS_DB_PASSWORD"]
      KETO_DB_PASSWORD              = local.generated_secrets["KETO_DB_PASSWORD"]
      HYDRA_DB_PASSWORD             = local.generated_secrets["HYDRA_DB_PASSWORD"]
      MCM_DB_PASSWORD               = local.generated_secrets["MCM_DB_PASSWORD"]
      HUB_ADMIN_PASSWORD            = local.generated_secrets["HUB_ADMIN_PASSWORD"]
      MCM_OIDC_CLIENT_SECRET        = local.generated_secrets["MCM_OIDC_CLIENT_SECRET"]
      ROLE_ASSIGN_SVC_SECRET        = local.generated_secrets["ROLE_ASSIGN_SVC_SECRET"]
      KRATOS_SECRETS_CIPHER         = local.generated_secrets["KRATOS_SECRETS_CIPHER"]
      KRATOS_SECRETS_COOKIE         = local.generated_secrets["KRATOS_SECRETS_COOKIE"]
      KRATOS_SECRETS_CSRF_COOKIE    = local.generated_secrets["KRATOS_SECRETS_CSRF_COOKIE"]
      KRATOS_SECRETS_DEFAULT        = local.generated_secrets["KRATOS_SECRETS_DEFAULT"]
      HYDRA_SECRETS_SYSTEM          = local.generated_secrets["HYDRA_SECRETS_SYSTEM"]
      HYDRA_SECRETS_COOKIE          = local.generated_secrets["HYDRA_SECRETS_COOKIE"]
      BACKUP_S3_ACCESS_KEY          = lookup(local.s, "BACKUP_S3_ACCESS_KEY", "")
      BACKUP_S3_SECRET_KEY          = lookup(local.s, "BACKUP_S3_SECRET_KEY", "")
    } : {}
  )

  type = "Opaque"
}

# minio-buckets-values — buckets declared in object_storage.buckets plus the
# scoped user and per-bucket policy for each. Delivered as a Secret (not a
# ConfigMap) because the users[] entries carry generated secret keys. Helm
# list-merge replaces lists wholesale, so the buckets list re-states the
# system buckets from gitops/tooling-config/minio/minio-values.yaml.
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

# Deployer Helm value overrides — one object per values/<namespace>/<release>.yaml
# file, named <namespace>-<release>-values-override. Referenced by every
# HelmRelease via valuesFrom (optional: true). Files that reference no secret
# key become ConfigMaps; files that do arrive pre-classified in
# helm_value_secret_overrides and become Secrets instead (same name, same key).
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

resource "kubernetes_secret_v1" "helm_value_overrides" {
  # Keys are <namespace>-<release> file names, not secret material — strip the
  # sensitive mark inherited from the values so they can drive for_each.
  for_each = nonsensitive(toset(keys(var.helm_value_secret_overrides)))

  metadata {
    name      = "${each.key}-values-override"
    namespace = var.flux_namespace
  }

  data = {
    "values.yaml" = var.helm_value_secret_overrides[each.key]
  }

  type = "Opaque"
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
  # hub-data: one Kustomization per in-cluster store + a common slice.
  in_cluster_stores = local.is_hub && local.is_talos ? sort([
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
  auth_depends = contains(local.in_cluster_stores, "mysql") ? ["hub-data-mysql"] : ["hub"]
  app_depends = concat(
    ["hub-auth-config"],
    [for store in local.in_cluster_stores : "hub-data-${store}" if store != "mysql"],
  )

  # Per-store Kustomizations (always same shape; enabled drives inclusion)
  data_kustomizations = merge(
    {
      "hub-data-common" = {
        enabled            = length(local.in_cluster_stores) > 0
        path               = "./hub-data/common"
        depends_on         = ["hub"]
        timeout            = "5m"
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
    },
    {
      for store, cfg in var.data_stores :
      "hub-data-${store}" => {
        enabled            = contains(local.in_cluster_stores, store)
        path               = "./hub-data/${store}"
        depends_on         = ["hub-data-common"]
        timeout            = "20m"
        wait               = false
        health_checks      = local.store_health[store].health_checks
        health_check_exprs = local.store_health[store].health_check_exprs
      }
    },
  )

  # object_storage.enabled = false — switch the backup machinery off structurally.
  # postBuild substitution can only swap scalars inside manifests; removing
  # the PXC schedule or flipping booleans needs kustomize patches, attached
  # here to the Kustomizations that own each consumer. PSMDB >=1.22 gates
  # cluster readiness AND app-user creation on PBM reaching its storage, so
  # shipping a backup config without a reachable endpoint deadlocks hub-app.
  backup_disabled_patches = {
    for k, v in {
      "hub-data-mongodb" = [{
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
      "hub-data-mysql" = [{
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
      "hub-auth" = [{
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

  # ACME External Account Binding — required by every public CA except Let's
  # Encrypt. The block must be *absent*, not empty, for CAs that do not use it:
  # an empty keyID makes cert-manager attempt EAB registration and the CA
  # answers "Invalid MAC on JWS request". postBuild substitution cannot omit a
  # YAML block, so the conditional happens here and kustomize does the merge.
  #
  # One patch covers all three gitops/dns/<provider> directories: patches target
  # by kind+name, not by path, so the issuer is matched wherever it came from.
  #
  # keyID stays a ${...} placeholder rather than the resolved value — patches
  # are applied during kustomize build and substitution runs after, so it
  # resolves from cluster-secrets instead of being written into the
  # Kustomization resource stored in the cluster.
  #
  # Built as a for-expression rather than a conditional object constructor:
  # `has_eab ? {"dns" = [...]} : {}` unifies to an object, whose per-attribute
  # types give lookup() no single element type to match its default against.
  # The filtered for yields a real map, exactly like backup_disabled_patches.
  eab_patches = {
    for k, v in {
      "dns" = [{
        patch = yamlencode({
          apiVersion = "cert-manager.io/v1"
          kind       = "ClusterIssuer"
          metadata   = { name = "acme-prod" }
          spec = {
            acme = {
              externalAccountBinding = {
                keyID = "$${ACME_EAB_KEY_ID}"
                keySecretRef = {
                  name = "acme-eab-credentials"
                  key  = "hmac-encoded"
                }
              }
            }
          }
        })
        target = {
          group   = "cert-manager.io"
          version = "v1"
          kind    = "ClusterIssuer"
          name    = "acme-prod"
        }
      }]
    } : k => v if local.has_eab
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
      # role chain entry (tooling or hub); "bare" gets no role kustomization
      (var.cluster_role) = {
        enabled    = var.cluster_role != "bare"
        path       = "./${var.cluster_role}"
        depends_on = [local.has_vendor ? local.vendor_name : "platform-config"]
        timeout    = local.is_hub ? "10m" : "5m"
        wait       = false
        health_checks = local.is_hub ? [
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "psmdb-operator", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "pxc-operator", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "strimzi-kafka-operator", namespace = var.flux_namespace },
        ] : []
        health_check_exprs = []
      }
      # --- tooling chain ---
      "tooling-config" = {
        enabled    = local.is_tooling
        path       = "./tooling-config"
        depends_on = ["tooling"]
        timeout    = "20m"
        wait       = false
        health_checks = [
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "minio", namespace = var.flux_namespace },
          { apiVersion = "helm.toolkit.fluxcd.io/v2", kind = "HelmRelease", name = "harbor", namespace = var.flux_namespace },
        ]
        health_check_exprs = []
      }
      "tooling-routes" = {
        enabled            = local.is_tooling
        path               = "./tooling-routes"
        depends_on         = ["tooling-config"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      "tooling-observability" = {
        enabled    = local.is_tooling
        path       = "./tooling-observability"
        depends_on = ["tooling-config"]
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
      "tooling-observability-routes" = {
        enabled            = local.is_tooling
        path               = "./tooling-observability-routes"
        depends_on         = ["tooling-observability"]
        timeout            = ""
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      # --- hub chain ---
      "hub-auth" = {
        enabled    = local.is_hub
        path       = "./hub-auth"
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
      "hub-auth-config" = {
        enabled            = local.is_hub
        path               = "./hub-auth-config"
        depends_on         = ["hub-auth"]
        timeout            = "10m"
        wait               = false
        health_checks      = []
        health_check_exprs = []
      }
      "hub-app" = {
        enabled    = local.is_hub
        path       = "./hub-app"
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
      "hub-observability-agent" = {
        enabled            = local.is_hub
        path               = "./hub-observability-agent"
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

  # Distribution patches first, deployer patches second: kustomize applies the
  # list in order, so the deployer's win. A patches/<name>.yaml naming no
  # enabled Kustomization is ignored — nothing here validates the filename.
  effective_patches = {
    for k, _ in local.kustomizations : k => concat(
      lookup(local.backup_disabled_patches, k, []),
      lookup(local.eab_patches, k, []),
      lookup(var.kustomize_patches, k, []),
    )
  }
}

# Cross-field validation over .env credentials, which the config.yaml JSON
# Schema cannot see — it is handed only config.yaml (see Makefile: validate).
resource "terraform_data" "cert_validation" {
  lifecycle {
    precondition {
      condition     = (lookup(local.s, "ACME_EAB_KEY_ID", "") != "") == (lookup(local.s, "ACME_EAB_HMAC_ENCODED", "") != "")
      error_message = "ACME EAB needs both ACME_EAB_KEY_ID and ACME_EAB_HMAC_ENCODED in .env, or neither. Half-configured, the issuer registers without EAB and the CA rejects issuance with 'Invalid MAC on JWS request'."
    }
  }
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
      length(local.effective_patches[each.key]) > 0 ? {
        patches = local.effective_patches[each.key]
      } : {},
    )
  })

  depends_on = [
    kubectl_manifest.oci_repository,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets,
  ]
}
