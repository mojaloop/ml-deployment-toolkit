# Adding Services

[docs](../index.md) / [platform](index.md) / Adding Services

**Audiences:** platform engineer

This page covers how to add platform services, vendor-specific services, DNS providers, and role-specific services to the ML Deployment Toolkit gitops artifact. For the architectural rationale behind the gitops directory structure and dependency chain, see [GitOps structure](../architecture/gitops-structure.md).

## Adding a platform service

Platform services live in `gitops/platform/` and are deployed to every cluster regardless of provider or role.

### 1. Create the service directory

```
gitops/platform/<service>/
  helmrelease.yaml
```

### 2. Write the HelmRelease

Use Flux `${variable}` placeholders for values that vary per environment. These are substituted at reconciliation time from the `cluster-config` ConfigMap and `cluster-secrets` Secret.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: my-service
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.example.com
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-service
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: my-service
      version: "1.x"
      sourceRef:
        kind: HelmRepository
        name: my-service
      interval: 12h
  targetNamespace: my-service
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    domain: ${domain}
    clusterName: ${cluster_name}
```

Raw manifests work too -- any valid Kubernetes YAML can go in the service directory.

### 3. Register in the platform kustomization

Add the new file to `gitops/platform/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - metrics-server/helmrelease.yaml
  - cert-manager/helmrelease.yaml
  - external-dns/helmrelease.yaml
  - external-secrets/helmrelease.yaml
  - my-service/helmrelease.yaml          # <-- new
```

### 4. Publish

```bash
make push-gitops ENV=cc
```

Flux will reconcile the new service on the next poll interval (default 10 minutes) or immediately if you trigger a reconciliation.

## Adding a vendor-specific service

Vendor services are deployed only on specific infrastructure providers. Add to the appropriate vendor kustomization:

| Provider | Directory | Examples |
|----------|-----------|----------|
| Proxmox / OpenStack (Talos) | `gitops/talos/` | Cilium HelmRelease, LB-IPAM pools, OpenEBS |
| AWS EKS | `gitops/aws/` | Cilium (BYOCNI), AWS-specific configs |
| GCP GKE | `gitops/gcp/` | Minimal (GKE manages most natively) |

The process is the same as platform services: create the manifest, add it to the vendor's `kustomization.yaml`, and publish. The difference is that it only deploys when `infra.provider` matches.

## Adding a DNS provider

DNS is an independent dimension from the infrastructure provider. A Cloudflare DNS configuration works on Proxmox, AWS, or GCP clusters. Adding a new DNS provider requires changes in gitops only -- zero Terraform module changes.

### 1. Create the DNS directory

Create `gitops/dns/<new_provider>/` with these files:

**`letsencrypt.yaml`** -- ClusterIssuers (prod + staging) with the provider-specific DNS-01 solver:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${alert_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          <provider-specific-solver>:
            tokenSecretRef:
              name: dns-provider-credentials
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${alert_email}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - dns01:
          <provider-specific-solver>:
            tokenSecretRef:
              name: dns-provider-credentials
              key: api-token
```

**`dns-secret.yaml`** -- Kubernetes Secret with DNS credentials using substitution variables:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dns-provider-credentials
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "${new_provider_api_token}"
```

**`kustomization.yaml`** -- registers the resources:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - dns-secret.yaml
  - letsencrypt.yaml
```

Some providers also need an **`external-dns-values.yaml`** HelmRelease values patch if the base external-dns configuration in `gitops/platform/` does not cover the provider's authentication mechanism.

### 2. Add credential variable to Makefile

Add one entry to the `dns_credentials` JSON map in the Makefile's `LOAD_ENV` block:

```makefile
TF_VAR_dns_credentials='{"digitalocean_token":"'$${DIGITALOCEAN_TOKEN:-}'",'`\
  `'"cloudflare_api_token":"'$${CLOUDFLARE_API_TOKEN:-}'",'`\
  `'"new_provider_api_token":"'$${NEW_PROVIDER_API_TOKEN:-}'",'`\   # <-- new
  ...
```

This maps the clean `.env` variable name to the `${new_provider_api_token}` placeholder used in Flux substitution.

### 3. Set the DNS provider in config.yaml

Adopters select the DNS provider in their environment config:

```yaml
dns:
  provider: new_provider
  domain: example.com
```

Flux deploys the `gitops/dns/new_provider/` kustomization based on this value.

## Adding a role-specific service

Role-specific services are deployed based on the cluster's role (`cc` or `env`).

### Tooling Cluster services (optional -- role: cc)

The Tooling Cluster has a three-stage dependency chain:

| Stage | Directory | Purpose |
|-------|-----------|---------|
| Operators | `gitops/cc/` | Vault operator, namespace definitions |
| Services | `gitops/cc-config/` | Vault CR, Harbor, MinIO, ESO SecretStore |
| Routes | `gitops/cc-routes/` | HTTPRoutes for Vault, Harbor, MinIO |

Add new Tooling Cluster services to `gitops/cc-config/` (most common) or `gitops/cc-routes/` (if it is an HTTPRoute). If the service needs a CRD-installing operator, add the operator to `gitops/cc/` and the CR to `gitops/cc-config/`.

### App Environment services (role: env)

App Environment has a four-stage dependency chain:

| Stage | Directory | Purpose |
|-------|-----------|---------|
| Operators | `gitops/env/` | Database operators (Percona, Strimzi) |
| Data | `gitops/env-data/` | Database CRs (MySQL, Kafka, MongoDB, Redis) |
| Auth | `gitops/env-auth/` | Vault, Keycloak, Ory stack (Kratos, Keto, Oathkeeper) |
| App | `gitops/env-app/` | Mojaloop core, MCM, Finance Portal, DFSP mTLS |

Choose the stage that matches your service's dependencies. If it depends on the database layer, it goes in `env-auth` or later. If it depends on auth, it goes in `env-app`.

## Variable substitution reference

All manifests in the gitops artifact can use `${variable}` placeholders. These are resolved by Flux postBuild substitution from two sources:

**ConfigMap (`cluster-config`)** -- non-sensitive values:

| Variable | Example | Scope |
|----------|---------|-------|
| `cluster_name` | `cc` | All |
| `domain` | `example.com` | All |
| `dns_provider` | `digitalocean` | All |
| `gateway_class_name` | `cilium` | All |
| `alert_email` | `ops@example.com` | All |
| `lb_ipam_range` | `10.0.0.100-10.0.0.110` | All |
| `lb_ipam_start` | `10.0.0.100` | All |
| `lb_ipam_stop` | `10.0.0.110` | All |
| `mysql_host` | `mojaloop-db-haproxy.mojaloop.svc.cluster.local` | env only |
| `kafka_host` | `mojaloop-kafka-kafka-bootstrap` | env only |

**Secret (`cluster-secrets`)** -- sensitive values:

| Variable | Source (.env) | Scope |
|----------|---------------|-------|
| `oci_repo_username` | `OCI_REPO_USERNAME` | All |
| `oci_repo_password` | `OCI_REPO_PASSWORD` | All |
| `oci_proxy_username` | `OCI_PROXY_USERNAME` | All |
| `oci_proxy_password` | `OCI_PROXY_PASSWORD` | All |
| DNS credentials | Provider-specific | All |
| Database passwords | `MYSQL_ROOT_PASSWORD`, etc. | env only |
| OIDC secrets | `HUBOP_OIDC_SECRET`, etc. | env only |

For the full list of available variables, see [GitOps structure -- personalization model](../architecture/gitops-structure.md#personalization-model).

## Directory conventions

| Directory | Scope | When deployed |
|-----------|-------|---------------|
| `platform/` | All clusters | Always |
| `platform-config/` | All clusters | Always (after platform) |
| `dns/{provider}/` | All clusters | Based on `dns.provider` |
| `talos/`, `aws/`, `gcp/` | Vendor-specific | Based on `infra.provider` |
| `cc/`, `cc-config/`, `cc-routes/` | Tooling Cluster | `cluster.role: cc` |
| `env/`, `env-data/`, `env-auth/`, `env-app/` | App Environment | `cluster.role: env` |

The deployment order follows the dependency chain: platform -> dns -> platform-config -> vendor -> role-specific stages. Each stage waits for the previous stage's health checks before proceeding.
