# Flux Config Module
# Creates Kubernetes resources for Flux OCI-based GitOps
# Deploys: 1 OCIRepository + Kustomizations (platform → dns/{provider} → platform-config → [vendor] → role-specific → ...)
#
# Two independent provider dimensions:
#   - infra_provider (proxmox, aws, gcp, openstack, digitalocean) → selects vendor kustomization
#   - dns_provider (digitalocean, cloudflare, route53) → selects dns kustomization (gitops/dns/{provider})

locals {
  has_oci_credentials = var.oci_repo_username != "" && var.oci_repo_password != ""
  is_talos            = contains(["proxmox", "openstack"], var.infra_provider)
  has_vendor          = contains(["proxmox", "openstack", "aws", "gcp"], var.infra_provider)
  is_env              = var.cluster_role == "env"

  # Extract registry host from artifact URL (e.g. "oci://ghcr.io/kiswend/ml-deployment-toolkit" → "ghcr.io")
  oci_registry = local.has_oci_credentials ? split("/", replace(var.artifact_url, "oci://", ""))[0] : ""

  # Docker config JSON for Flux source-controller authentication
  dockerconfigjson = local.has_oci_credentials ? jsonencode({
    auths = {
      (local.oci_registry) = {
        username = var.oci_repo_username
        password = var.oci_repo_password
        auth     = base64encode("${var.oci_repo_username}:${var.oci_repo_password}")
      }
    }
  }) : ""

  # Data layer endpoints — self-hosted uses in-cluster FQDNs (data ns), managed uses cloud service endpoints
  mysql_host   = local.is_talos ? "mojaloop-db-haproxy.data.svc.cluster.local" : var.mysql_host
  mysql_port   = local.is_talos ? "3306" : var.mysql_port
  kafka_host   = local.is_talos ? "mojaloop-kafka-kafka-bootstrap.data.svc.cluster.local" : var.kafka_host
  kafka_port   = local.is_talos ? "9092" : var.kafka_port
  mongodb_host = local.is_talos ? "bulk-mongodb-rs0.data.svc.cluster.local" : var.mongodb_host
  mongodb_port = local.is_talos ? "27017" : var.mongodb_port
  redis_host   = local.is_talos ? "ttk-redis.data.svc.cluster.local" : var.redis_host
  redis_port   = local.is_talos ? "6379" : var.redis_port
}

# Kratos secrets — generated once, stored in Terraform state, seeded into Vault via cluster-secrets → Flux substitution
resource "random_password" "kratos_secrets_cipher" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "kratos_secrets_cookie" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "kratos_secrets_csrf_cookie" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "kratos_secrets_default" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

# Hydra secrets — generated once, stored in Terraform state, seeded into Vault via cluster-secrets → Flux substitution
resource "random_password" "hydra_secrets_system" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "hydra_secrets_cookie" {
  count   = local.is_env ? 1 : 0
  length  = 32
  special = false
}

# ConfigMap with cluster configuration for postBuild substitution
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = var.flux_namespace
  }

  data = merge(
    {
      cluster_name       = var.cluster_name
      cluster_vip        = var.cluster_vip
      domain             = var.domain
      dns_provider       = var.dns_provider
      gateway_class_name = var.gateway_class_name
      alert_email        = var.alert_email
      lb_ipam_range      = var.lb_ipam_range
      lb_ipam_start      = split("-", var.lb_ipam_range)[0]
      lb_ipam_stop       = split("-", var.lb_ipam_range)[1]
      loki_url           = var.loki_url
      mimir_url          = var.mimir_url
      tempo_url          = var.tempo_url
    },
    local.is_env ? {
      mysql_host   = local.mysql_host
      mysql_port   = local.mysql_port
      kafka_host   = local.kafka_host
      kafka_port   = local.kafka_port
      mongodb_host = local.mongodb_host
      mongodb_port = local.mongodb_port
      redis_host   = local.redis_host
      redis_port   = local.redis_port

      hub_participant_name     = var.hub_participant_name
      onboarding_funds_in      = var.onboarding_funds_in
      onboarding_net_debit_cap = var.onboarding_net_debit_cap

      api_type = var.api_type

      backup_s3_endpoint = var.backup_s3_endpoint
      backup_s3_bucket   = var.backup_s3_bucket
      backup_s3_region   = var.backup_s3_region
    } : {},
    var.profile_vars,
  )
}

# Secret with sensitive credentials for postBuild substitution
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = merge(
    var.dns_credentials,
    {
      oci_repo_username      = var.oci_repo_username
      oci_repo_password      = var.oci_repo_password
      oci_proxy_username     = var.oci_proxy_username
      oci_proxy_password     = var.oci_proxy_password
      minio_root_user        = var.minio_root_user
      minio_root_password    = var.minio_root_password
      harbor_admin_password  = var.harbor_admin_password
      grafana_admin_password = var.grafana_admin_password
      # SMTP + alerting delivery: needed on cc (Grafana alerting) and env
      # (Kratos courier), so they live in the common block
      smtp_host          = var.smtp_host
      smtp_port          = var.smtp_port
      smtp_user          = var.smtp_user
      smtp_password      = var.smtp_password
      alert_email_from   = var.alert_email_from
      alert_email_to     = var.alert_email_to
      telegram_bot_token = var.telegram_bot_token
      telegram_chat_id   = var.telegram_chat_id
    },
    local.is_env ? {
      mysql_root_password           = var.mysql_root_password
      mysql_central_ledger_password = var.mysql_central_ledger_password
      mysql_account_lookup_password = var.mysql_account_lookup_password
      mysql_oracle_msisdn_password  = var.mysql_oracle_msisdn_password
      mongodb_root_password         = var.mongodb_root_password
      mongodb_app_password          = var.mongodb_app_password
      keycloak_db_password          = var.keycloak_db_password
      kratos_db_password            = var.kratos_db_password
      keto_db_password              = var.keto_db_password
      mcm_db_password               = var.mcm_db_password
      hub_admin_password            = var.hub_admin_password
      hub_admin_email               = var.hub_admin_email
      hubop_oidc_secret             = var.hubop_oidc_secret
      mcm_oidc_client_secret        = var.mcm_oidc_client_secret
      role_assign_svc_secret        = var.role_assign_svc_secret
      dfsp_oidc_client_secret       = var.dfsp_oidc_client_secret
      kratos_secrets_cipher         = random_password.kratos_secrets_cipher[0].result
      kratos_secrets_cookie         = random_password.kratos_secrets_cookie[0].result
      kratos_secrets_csrf_cookie    = random_password.kratos_secrets_csrf_cookie[0].result
      kratos_secrets_default        = random_password.kratos_secrets_default[0].result
      hydra_db_password             = var.hydra_db_password
      hydra_secrets_system          = random_password.hydra_secrets_system[0].result
      hydra_secrets_cookie          = random_password.hydra_secrets_cookie[0].result
      backup_s3_access_key          = var.backup_s3_access_key
      backup_s3_secret_key          = var.backup_s3_secret_key
    } : {}
  )

  type = "Opaque"
}

# Deployer Helm value overrides — one ConfigMap per chart with a non-empty override
# Referenced by HelmRelease.valuesFrom (optional: true), merged on top of the platform-team's inline values.
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

# OCI registry credentials secret (for Flux source-controller to pull from private registry)
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

# Kustomization: platform (shared — always deployed first)
resource "kubectl_manifest" "kustomization_platform" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "platform"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./platform"
      prune    = true
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "external-secrets-external-secrets-webhook"
          namespace  = "external-secrets"
        },
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "cert-manager-cert-manager-webhook"
          namespace  = "cert-manager"
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.oci_repository,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets
  ]
}

# Kustomization: dns/{provider} (DNS-provider-specific: ClusterIssuers, DNS Secret, external-dns values patch)
resource "kubectl_manifest" "kustomization_dns" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "dns"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./dns/${var.dns_provider}"
      prune    = true
      dependsOn = [
        { name = "platform" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform
  ]
}

# Kustomization: platform-config (Gateway, wildcard TLS — depends on dns for ClusterIssuers)
resource "kubectl_manifest" "kustomization_platform_config" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "platform-config"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./platform-config"
      prune    = true
      dependsOn = [
        { name = "dns" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_dns
  ]
}

# Kustomization: vendor (infra-provider-specific gap fillers — Cilium, LB, storage, registry)
resource "kubectl_manifest" "kustomization_vendor" {
  count = local.has_vendor ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = local.is_talos ? "talos" : var.infra_provider
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./${local.is_talos ? "talos" : var.infra_provider}"
      prune    = true
      dependsOn = [
        { name = "platform-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform_config
  ]
}

# Kustomization: role-specific (cc or env — deployed after vendor kustomization)
# Skipped for "base" role which only needs platform + dns + platform-config + vendor
resource "kubectl_manifest" "kustomization_role" {
  count = var.cluster_role != "base" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = var.cluster_role
      namespace = var.flux_namespace
    }
    # env clusters: wait for operators to install CRDs before env-data can apply CRs
    spec = {
      interval = "10m"
      timeout  = local.is_env ? "10m" : "5m"
      path     = "./${var.cluster_role}"
      prune    = true
      dependsOn = local.has_vendor ? [
        { name = local.is_talos ? "talos" : var.infra_provider }
        ] : [
        { name = "platform-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = local.is_env ? [
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "psmdb-operator"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "pxc-operator"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "strimzi-kafka-operator"
          namespace  = var.flux_namespace
        }
      ] : []
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform_config,
    kubectl_manifest.kustomization_vendor
  ]
}

# Kustomization: cc-config (Vault CR, ESO SecretStore, MinIO, Harbor — depends on cc installing vault-operator CRDs)
resource "kubectl_manifest" "kustomization_cc_config" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-config"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./cc-config"
      prune    = true
      dependsOn = [
        { name = "cc" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "minio"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "harbor"
          namespace  = var.flux_namespace
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_role
  ]
}

# Kustomization: cc-routes (HTTPRoutes for CC services — depends on cc-config so backend services exist)
resource "kubectl_manifest" "kustomization_cc_routes" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-routes"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./cc-routes"
      prune    = true
      dependsOn = [
        { name = "cc-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_cc_config
  ]
}

# Kustomization: cc-observability (Observability stack: Thanos, Loki, Tempo, Grafana — depends on cc-config for MinIO buckets)
resource "kubectl_manifest" "kustomization_cc_observability" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-observability"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./cc-observability"
      prune    = true
      dependsOn = [
        { name = "cc-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "apps/v1"
          kind       = "StatefulSet"
          name       = "thanos-receive"
          namespace  = "observability"
        },
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "thanos-query"
          namespace  = "observability"
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "loki"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "tempo"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "grafana"
          namespace  = var.flux_namespace
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_cc_config
  ]
}

# Kustomization: cc-observability-routes (HTTPRoutes for observability services — depends on cc-observability)
resource "kubectl_manifest" "kustomization_cc_observability_routes" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-observability-routes"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./cc-observability-routes"
      prune    = true
      dependsOn = [
        { name = "cc-observability" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_cc_observability
  ]
}

# Kustomization: env-data (self-hosted data layer — operators deploy CRs for MySQL, Kafka, MongoDB, Redis)
resource "kubectl_manifest" "kustomization_env_data" {
  count = local.is_talos && local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-data"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./env-data"
      prune    = true
      dependsOn = [
        { name = "env" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      # CEL-based health check: PXC CR .status.state must be 'ready' (all nodes synced + proxies healthy)
      # Matches ALL PerconaXtraDBCluster CRs — gates downstream kustomizations from starting migrations before DDL is safe
      healthCheckExprs = [
        {
          apiVersion = "pxc.percona.com/v1"
          kind       = "PerconaXtraDBCluster"
          inProgress = "!has(status.state) || status.state == 'initializing'"
          current    = "has(status.state) && status.state == 'ready'"
          failed     = "has(status.state) && status.state == 'error'"
        }
      ]
      healthChecks = [
        {
          apiVersion = "kafka.strimzi.io/v1beta2"
          kind       = "Kafka"
          name       = "mojaloop-kafka"
          namespace  = "data"
        },
        {
          apiVersion = "psmdb.percona.com/v1"
          kind       = "PerconaServerMongoDB"
          name       = "bulk-mongodb"
          namespace  = "data"
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_role
  ]
}

# Kustomization: env-auth (auth layer — Vault, Keycloak, Ory stack, HTTPRoutes)
resource "kubectl_manifest" "kustomization_env_auth" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-auth"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./env-auth"
      prune    = true
      dependsOn = local.is_talos ? [
        { name = "env-data" }
        ] : [
        { name = "env" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "vault.banzaicloud.com/v1alpha1"
          kind       = "Vault"
          name       = "vault"
          namespace  = "vault"
        },
        # Ory stack
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "kratos"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "keto"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "hydra"
          namespace  = var.flux_namespace
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_role,
    kubectl_manifest.kustomization_env_data,
    kubectl_manifest.kustomization_vendor
  ]
}

# Kustomization: env-auth-config (bootstrap jobs — depends on env-auth being healthy)
resource "kubectl_manifest" "kustomization_env_auth_config" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-auth-config"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "10m"
      path     = "./env-auth-config"
      prune    = true
      dependsOn = [
        { name = "env-auth" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_env_auth
  ]
}

# Kustomization: env-app (Mojaloop core + MCM + Finance Portal — always deployed for env clusters)
resource "kubectl_manifest" "kustomization_env_app" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-app"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "30m"
      path     = "./env-app"
      prune    = true
      dependsOn = [
        { name = "env-auth-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "mojaloop"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "mcm"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "finance-portal"
          namespace  = var.flux_namespace
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_role,
    kubectl_manifest.kustomization_env_data,
    kubectl_manifest.kustomization_env_auth,
    kubectl_manifest.kustomization_env_auth_config,
    kubectl_manifest.kustomization_vendor
  ]
}

# Kustomization: env-observability-agent (Grafana Alloy for log collection — only deployed to env clusters)
resource "kubectl_manifest" "kustomization_env_observability_agent" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-observability-agent"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "5m"
      path     = "./env-observability-agent"
      prune    = true
      wait     = true
      dependsOn = [
        { name = "platform-config" } # Needs Gateway/DNS for remote write
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.oci_repository,
    kubectl_manifest.kustomization_platform_config
  ]
}
