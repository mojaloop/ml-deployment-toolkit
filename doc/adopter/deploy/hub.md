# Deploy a Hub

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Hub

**Audiences:** adopter (deploy)

A Hub (`role: env`) runs the Mojaloop switch — central ledger, account lookup, quoting, settlements, MCM, the Ory auth stack, and the data layer. If a Tooling Cluster is in use, deploy it first.

For the shared workflow and commands, see [Deployment](deployment.md). This page is the `env`-specific configuration and checks.

- [Inputs](#inputs)
- [Configuration](#configuration)
- [Deploy](#deploy)
- [Verify the cluster](#verify-the-cluster)
- [Configure the Hub](#configure-the-hub)
- [Collect integration details](#collect-integration-details)
- [Harbor pull-through cache](#harbor-pull-through-cache)
- [After deploying](#after-deploying)

## Inputs

| Input | Example | Notes |
|-------|---------|-------|
| Proxmox nodes | `worker1`, `worker2`, `worker3` | A Hub is multi-node |
| Kubernetes API VIP | `192.168.0.214` | Floating IP |
| LB-IPAM range | `192.168.0.215-217` | **Three** addresses |
| DNS zone | `sw1.example.com` | Delegated before deploying |
| Artifact version | `v0.9.0` or `latest` | Same artifact as the Tooling Cluster |
| SMTP | **required** | MCM sends participant activation emails — a Hub without SMTP cannot onboard |
| Tooling Cluster domain | `cc1.example.com` | One value; endpoints are derived — see [hand-off](tooling-cluster.md#hand-off-to-the-hub) |

## Configuration

The distinguishing settings in `config.yaml`:

```yaml
version: 1
template: "tps-10"          # tps-1 | tps-10
cluster:
  name: "my-hub"            # must equal the environment directory name
  role: "env"
  vip: "192.168.0.214"
  lb_ipam:
    range: "192.168.0.215-192.168.0.217"   # three addresses
dns:
  provider: "cloudflare"
  domain: "sw1.example.com"
email:                      # required — activation mail
  host: "smtp.example.com"
  port: "587"
  from: "no-reply@example.com"
app:
  api_type: "fspiop"        # fspiop | iso20022 — set once, see below
  hub:
    participant_name: "Hub"
    admin_email: "hub-admin@example.com"
```

**A Hub needs three LB addresses** — `gw-int`, `gw-ext`, and the FSPIOP `extapi` endpoint.

**`app.api_type` is set once.** It selects the FSPIOP message dialect. Switching it on a running Hub breaks in-progress transfers — decide it before the first deploy.

Start from `environments/mlf-lab1-sw1/config.yaml.sample`, which carries the full Hub shape including the `data` section. The complete reference is [Configuration](configuration.md).

A Hub runs far more internal services than a Tooling Cluster — the databases and the Ory stack each need their own credentials — but the adopter authors none of them. They are generated at apply time and read back with `make secrets ENV=<hub-env>`. What `.env` still needs is in [Prerequisites](prerequisites.md#credentials-checklist). One value matters within minutes of deploying:

- **`app.hub.admin_email` and the generated `hub_admin_password`** are the HubOps login for both MCM and the Finance Portal, used in [Configure the Hub](#configure-the-hub).

### Supporting services

A Hub needs three supporting services: an image pull-through cache, a backup target, and a telemetry sink. Each is chosen independently and may point anywhere — a Tooling Cluster, a cloud service, or your own hosts. Write the endpoints out:

```yaml
registry:
  provider: "harbor"
  url: "harbor.int.cc1.example.com"          # no oci:// prefix
object_storage:
  provider: "s3"
  endpoint: "https://s3.int.cc1.example.com"
  bucket: "my-switch-backups"                # declared on the Tooling Cluster
observability:
  provider: "urls"
  loki_url: "https://loki.int.cc1.example.com/loki/api/v1/push"
  mimir_url: "https://thanos.int.cc1.example.com/api/v1/receive"
  tempo_url: "https://tempo.int.cc1.example.com/v1/traces"
```

Set any of the three to `provider: "none"` to disable it. Credentials stay in `.env` — `OCI_PROXY_*` for the registry, `BACKUP_S3_*` for object storage. When the target is a Tooling Cluster, both accounts are declared there and scoped to this Hub: a pull-only robot under `registry.robots` (convention: this `cluster.name`; `OCI_PROXY_USERNAME` is `robot-<name>`) and a bucket under `object_storage.buckets` (convention: `<this cluster.name>-backups`; `BACKUP_S3_ACCESS_KEY` is the bucket name). Both passwords come from `make secrets ENV=<cc-env>` — see the [hand-off](tooling-cluster.md#hand-off-to-the-hub). The telemetry sink has no credential field yet, so those URLs must be reachable without authentication (a private network, or mTLS terminated at the gateway); managed backends that require a token are not supported today.

The Harbor proxy is a Talos-level registry mirror, transparent to the workloads.

#### Shorthand when a Tooling Cluster provides all three

If a Tooling Cluster deployed by this toolkit backs all three services, name it once instead:

```yaml
toolkit_cc:
  domain: "cc1.example.com"

registry:
  provider: "toolkit-cc"    # -> harbor.int.<domain>
object_storage:
  provider: "toolkit-cc"    # -> https://s3.int.<domain>
  bucket: "my-switch-backups"
observability:
  provider: "toolkit-cc"    # -> loki/thanos/tempo push URLs
```

This derives the same five endpoints from the one domain, so changing it later is a single edit rather than five. The resulting configuration is identical to writing them out — the shorthand only saves transcription. It relies on the URL layout this distribution gives its Tooling Cluster routes, so prefer the explicit form when the Hub and Tooling Cluster are upgraded independently, or when anything other than a toolkit-deployed CC provides a service.

Either way, the two credentials that must be carried over are in the [hand-off](tooling-cluster.md#hand-off-to-the-hub).

### Data layer

By default all four stores run in-cluster, sized by the template. Any of them can point at an existing endpoint instead:

```yaml
data:
  mysql:
    mode: "external-unmanaged"
    host: "mysql.example.com"
    port: "3306"
```

That store's `env-data` Kustomization is then not created and the toolkit reconciles nothing for it — provisioning, tuning, and backups become the adopter's. Credentials go in `.env` under the generated name they replace (`MYSQL_ROOT_PASSWORD`). See [Configuration → Data modes](configuration.md#data-modes).

## Deploy

Confirm the DNS zone is delegated ([Pre-deploy checks](deployment.md#pre-deploy-checks)):

```bash
dig +short NS sw1.example.com
```

Then:

```bash
make validate ENV=<hub-env>
make plan-apply ENV=<hub-env>
```

Expect ~20–30 minutes for Terraform, then ~20–30 for Flux to converge the full stack — data layer, auth, then Mojaloop. The chain waits for the data layer to be healthy before the application layer starts, because migrations run against databases that must already exist. Apparent inactivity after `env-data` goes Ready is normal — see [Reconciliation order](../../architecture/system-overview.md#reconciliation-order).

## Verify the cluster

Check up the stack — VMs, Talos, Kubernetes — per [Deployment → Verify](deployment.md#verify-up-the-stack). The Hub-specific checks:

```bash
export KUBECONFIG=$(pwd)/artifacts/<hub-env>/kubernetes/kubeconfig

# Three gateways with addresses (extapi is a separate LoadBalancer service)
kubectl get gateways -n platform-system
kubectl get svc -n mojaloop cilium-gateway-gw-extapi

# Data layer — note the namespace is 'data', not 'mojaloop'
kubectl get perconaxtradbcluster -n data
kubectl get kafka -n data
kubectl get perconaservermongodb -n data

# Auth stack — namespace 'ory'
kubectl get pods -n ory

# Application HelmReleases reconcile in flux-system
kubectl get helmrelease -n flux-system mojaloop mcm finance-portal
```

**Watch the namespaces.** The data layer is in `data`, the auth stack in `ory`, and the Mojaloop HelmRelease is in `flux-system` — not `mojaloop`. Commands against `mojaloop` for these return an empty list that looks like success. See [System overview](../../architecture/system-overview.md#what-a-hub-runs).

The FSPIOP endpoint is a standalone LoadBalancer service named `cilium-gateway-gw-extapi` in the `mojaloop` namespace — despite the name, it is not a Gateway and will not appear in `kubectl get gateways`. See [Networking](../../architecture/networking.md#the-fspiop-endpoint-is-not-a-gateway).

Log in to the three operator UIs with the HubOps credentials to confirm they load — the user is `app.hub.admin_email` from `config.yaml`, and the password is generated:

```bash
make secrets ENV=<hub-env>     # hub_admin_password
```

| Service | URL |
|---------|-----|
| MCM | `https://mcm.int.<domain>` |
| Finance Portal | `https://finance-portal.int.<domain>` |
| Testing Toolkit | `https://ttk.int.<domain>` |

## Configure the Hub

**A freshly reconciled Hub is empty** — no currency, no ledger accounts, no settlement model, no oracle. It cannot process a transaction until the adopter provisions these, and skipping this step produces misleading failures much later (a party lookup that fails with an unrelated-looking error is almost always a missing oracle).

Flux must have fully converged first, or the Testing Toolkit will not be reachable:

```bash
kubectl get kustomizations -n flux-system   # all Ready: True
```

The bundled `ttk/onboard_new/1_hub.json` collection provisions everything, driven entirely by `ttk/onboard_new/1_hub_environment.json` — no values are hardcoded in the collection. It has four sections:

| Section | Creates | Re-run |
|---------|---------|--------|
| Hub Accounts | Multilateral settlement + reconciliation accounts | Once per currency |
| Hub Endpoints | The three hub notification endpoints | Once, ever |
| Settlement Model | One settlement model | Once per model |
| Oracle | One oracle | Once per oracle |

To run it:

1. Open the Testing Toolkit at `https://ttk.int.<domain>`
2. **Test Runner → Import Collection**, select `ttk/onboard_new/1_hub.json`
3. Import `ttk/onboard_new/1_hub_environment.json` as the environment
4. **Run**

As shipped, one run provisions what a first transaction needs: hub accounts in the configured currency, the three endpoints, a deferred-net settlement model, and a default MSISDN oracle.

**Every assertion must pass.** If the Oracle section fails, party lookup fails later with a misleading error — fix it here, not there.

To add a second currency, a different settlement model, or another oracle, change the environment file and re-run — no JSON editing. Give each settlement model a distinct name; the central ledger keys them by name and rejects duplicates. Re-running is otherwise safe — accounts, models, and oracles all tolerate "already exists".

Confirm it took effect: the currency and the hub's ledger accounts appear in the Finance Portal, and the oracle is registered.

## Collect integration details

These are the values every participant needs, identical for all of them. This is the hand-off to the [Participant guide](../../participant/index.md).

```bash
MCM_SERVER_ENDPOINT=https://mcm.ext.<domain>/pm4mlapi
HUB_IAM_PROVIDER_URL=https://hydra.ext.<domain>
HUB_EXTAPI_FQDN=extapi.<domain>
DFSP_CURRENCIES=<currency>
```

> A participant's ID and OAuth2 client credentials are **not** part of this hand-off. They exist only once HubOps creates the participant in MCM, and the participant generates its own secret — the Hub never holds it. See [Onboarding participants](../operate/onboarding-participants.md) and the [choreography](../../architecture/participant-integration.md#the-choreography).

## Harbor pull-through cache

When `registry.provider` is set, image pulls route through the Tooling Cluster's Harbor as a transparent cache — fetched from upstream on first pull, served locally after.

Confirm the mirror is configured on the nodes:

```bash
talosctl get registries.mirrors --talosconfig artifacts/<hub-env>/talos-config/talosconfig -n <vip>
```

Cached images appear in Harbor's proxy-cache projects with their upstream source and pull count.

## After deploying

**Back up the Hub's Vault unseal keys.** A Hub's Vault holds the scheme PKI — the CA that signs every participant certificate. Losing the unseal keys means losing the ability to open it.

```bash
kubectl -n vault get secrets
kubectl -n vault get secret <unseal-secret> -o yaml > vault-unseal-<hub-env>.yaml
```

Store it offline. See [Recover → Disaster recovery](../recover/disaster-recovery.md#what-the-adopter-must-keep).

Then:

- Onboard participants: [Operate → Onboarding participants](../operate/onboarding-participants.md)
- Set up monitoring: [Operate → Monitoring](../operate/monitoring.md)
- A participant connects from their side: [Participant guide](../../participant/index.md)
