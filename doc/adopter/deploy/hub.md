# Deploy a Hub

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Hub

**Audiences:** adopter (deploy)

A Hub (`role: env`) runs the Mojaloop switch — central ledger, account lookup, quoting, settlements, MCM, the Ory auth stack, and the data layer. If you use a Tooling Cluster, deploy it first.

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
| Tooling Cluster endpoints | from [Tooling Cluster hand-off](tooling-cluster.md#hand-off-to-the-hub) | Cache, S3, observability |

## Configuration

The distinguishing settings in `config.yaml`:

```yaml
profile: "tps-10"           # tps-1 | tps-10
cluster:
  name: "my-hub"
  role: "env"
  vip: "192.168.0.214"
dns:
  provider: "cloudflare"
  domain: "sw1.example.com"
app:
  lb_ipam:
    range: "192.168.0.215-192.168.0.217"   # three addresses
  api_type: "fspiop"        # fspiop | iso20022 — set once, see below
```

**A Hub needs three LB addresses** — `gw-int`, `gw-ext`, and the FSPIOP `extapi` endpoint.

**`api_type` is set once.** It selects the FSPIOP message dialect. Switching it on a running Hub breaks in-progress transfers — decide it before the first deploy.

A Hub carries far more secrets than a Tooling Cluster — the databases and the Ory stack each need their own. The full set is in [Prerequisites](prerequisites.md#credentials-checklist); missing database credentials are the most common cause of a Hub that provisions but never becomes healthy. One in particular:

- **`HUB_ADMIN_EMAIL` / `HUB_ADMIN_PASSWORD`** are the HubOps login for both MCM and the Finance Portal. You use them minutes after deploy, in [Configure the Hub](#configure-the-hub).

### Pointing at a Tooling Cluster

If this Hub uses a Tooling Cluster, carry over its endpoints:

```yaml
oci:
  proxy:
    active: true
    url: "harbor.int.<cc-domain>"     # image pulls route through Harbor
backup:
  s3: "https://s3.int.<cc-domain>"
observability:
  mimir_url: "https://thanos.int.<cc-domain>/api/v1/receive"
  loki_url:  "https://loki.int.<cc-domain>/loki/api/v1/push"
  tempo_url: "https://tempo.int.<cc-domain>/v1/traces"
```

The Harbor proxy is a Talos-level registry mirror, transparent to the workloads.

## Deploy

Confirm the DNS zone is delegated ([Before you deploy](deployment.md#before-you-deploy)):

```bash
dig +short NS sw1.example.com
```

Then:

```bash
make init ENV=<hub-env>
make plan ENV=<hub-env>
make apply ENV=<hub-env>
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

Log in to the three operator UIs with the HubOps credentials to confirm they load:

```bash
grep -E '^HUB_ADMIN_(EMAIL|PASSWORD)=' config/environments/<hub-env>/.env
```

| Service | URL |
|---------|-----|
| MCM | `https://mcm.int.<domain>` |
| Finance Portal | `https://finance-portal.int.<domain>` |
| Testing Toolkit | `https://ttk.int.<domain>` |

## Configure the Hub

**A freshly reconciled Hub is empty** — no currency, no ledger accounts, no settlement model, no oracle. It cannot process a transaction until you provision these, and skipping this step produces misleading failures much later (a party lookup that fails with an unrelated-looking error is almost always a missing oracle).

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
DFSP_CURRENCIES=<your currency>
```

If a Tooling Cluster is deployed, also share the observability endpoints so participants can ship telemetry to it.

> A participant's ID and OAuth2 client credentials are **not** part of this hand-off. They exist only once HubOps creates the participant in MCM, and the participant generates its own secret — the Hub never holds it. See [Onboarding participants](../operate/onboarding-participants.md) and the [choreography](../../architecture/participant-integration.md#the-choreography).

## Harbor pull-through cache

When `oci.proxy.active: true`, image pulls route through the Tooling Cluster's Harbor as a transparent cache — fetched from upstream on first pull, served locally after.

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

Store it offline. See [Recover → Disaster recovery](../recover/disaster-recovery.md#what-you-must-keep).

Then:

- Onboard participants: [Operate → Onboarding participants](../operate/onboarding-participants.md)
- Set up monitoring: [Operate → Monitoring](../operate/monitoring.md)
- A participant connects from their side: [Participant guide](../../participant/index.md)
