# Configuration

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Configuration

**Audiences:** adopter (deploy)

Two files describe an environment: `config.yaml` for what the deployment is, and `.env` for the credentials it needs from the outside world. Everything specific to a deployment lives in these; the adopter never edits the distribution.

- [Vocabulary](#vocabulary)
- [Environment layout](#environment-layout)
- [config.yaml](#configyaml)
- [A Tooling Cluster, annotated](#a-tooling-cluster-annotated)
- [A Hub, annotated](#a-hub-annotated)
- [Deployment templates](#deployment-templates)
- [Data modes](#data-modes)
- [The toolkit-cc shorthand](#the-toolkit-cc-shorthand)
- [Secrets](#secrets)
- [Helm value overrides](#helm-value-overrides)
- [Validating](#validating)

## Vocabulary

The documentation uses reader-facing names; the configuration uses code values. They map one to one:

| Configuration value | The docs call it |
|---------------------|------------------|
| `role: cc` | Tooling Cluster |
| `role: env` | Hub |
| `dfsp`, `DFSP_ID` | Participant |

When a page says "deploy a Hub," set `role: env`. This is the only translation needed.

## Environment layout

Each environment is a directory under `environments/` at the repository root. `ENV=` selects it.

```
environments/
  my-cc/
    config.yaml        # what the deployment is
    .env               # external credentials (git-ignored)
    values/            # optional Helm overrides (git-ignored)
```

Environments are fully independent — their own config, secrets, and Terraform state. One repository clone manages any number of them. A Tooling Cluster and its Hubs are separate environments, each deployed with its own `make plan-apply ENV=<name>`.

**`cluster.name` defaults to the directory name** and can be omitted for a new deployment, so identity is normally one value rather than two. Set it explicitly only to keep a name a cluster already has — it is durable identity, becoming the external-dns record owner, the Vault backup prefix, and the VM name prefix, so changing it on a live cluster orphans its DNS records and forces VM replacement.

State and generated artifacts land under `artifacts/<env>/` — see [System overview](../../architecture/system-overview.md#configuration-tiers).

> **`environments/` is git-ignored, with two exceptions.** A fresh clone carries tracked samples at `environments/mlf-lab1-cc1/` (Tooling Cluster) and `environments/mlf-lab1-sw1/` (Hub), each holding a `config.yaml.sample` and a `.env.sample`. Copy a pair into a new directory and edit. Nothing else under `environments/` is ever tracked.

## config.yaml

`config.yaml` is a flat list of sections, one per **capability** — one dimension of the deployment, bound to a provider. Only `infra` and `dns` must be chosen; everything else defaults or is off.

| Section | Required | Choices | Default |
|---------|:---:|---------|---------|
| `version` | yes | `1` | — |
| `cluster` | yes | `name`, `role`, `vip`, `lb_ipam.range` | — |
| `template` | yes | a name under `config/templates/<role>/` | — |
| `infra` | yes | `proxmox`, `aws`, `digitalocean` | — |
| `dns` | yes | `digitalocean`, `cloudflare`, `route53` | — |
| `cert` | no | ACME contact email | `admin@<dns.domain>`, Let's Encrypt |
| `artifact` | no | the gitops OCI artifact Flux reconciles | none — no Kustomizations created |
| `toolkit_cc` | no | the backing Tooling Cluster's domain | — |
| `registry` | no | `toolkit-cc`, `harbor`, `none` | `none` (pull direct from upstream) |
| `object_storage` | no | `toolkit-cc`, `s3`, `none` | `none` |
| `observability` | no | `toolkit-cc`, `urls`, `none` | `none` |
| `data` | no (Hub only) | per store: `in-cluster-managed`, `external-unmanaged` | `in-cluster-managed` |
| `email` | no | SMTP relay for transactional mail | off |
| `alerting` | no | Grafana contact points — email, Telegram | off |
| `app` | no (Hub only) | `api_type`, hub identity, onboarding amounts | `fspiop`, `Hub` |

Three fields decide the shape of everything else:

| Field | Effect |
|-------|--------|
| `cluster.role` | Which Kustomizations deploy — `cc` or `env` — and which template directory is read |
| `template` | Node count, machine sizing, replica counts, data-layer tuning |
| `artifact.version` | `latest` follows publishes; a tag pins |

Sample files carry a `# yaml-language-server: $schema=` header on the first line. An editor with the YAML language server gives autocomplete and inline errors against the real schema — keep that line when copying.

**Address counts differ by role.** A Tooling Cluster needs two LB addresses; a Hub needs three, because it also has the FSPIOP endpoint. See [Networking](../../architecture/networking.md#load-balancer-addresses).

## A Tooling Cluster, annotated

From `environments/mlf-lab1-cc1/config.yaml.sample`:

```yaml
# yaml-language-server: $schema=../../config/schemas/environment.schema.json
version: 1

cluster:
  name: "my-cc"                       # optional — defaults to the directory name
  role: "cc"                          # cc | env | base
  vip: "192.168.0.210"                # Kubernetes API floating IP (on-prem only)
  lb_ipam:
    range: "192.168.0.211-192.168.0.213"

template: "medium"                    # config/templates/cc/medium.yaml

infra:
  provider: "proxmox"                 # proxmox | aws | digitalocean
  proxmox:
    placement:                        # template placement groups -> physical nodes
      pg-1: "pve-node-1"
    network_bridge: "vmbr0"
    storage:
      disks: "local-lvm"
      images: "local"
      snippets: "local"
  talos:                              # optional node OS overrides
    nameservers: ["8.8.8.8", "1.1.1.1"]
    ntp_servers: ["time.cloudflare.com"]

dns:
  provider: "route53"                 # digitalocean | cloudflare | route53
  domain: "cc1.lab1.example.com"

cert:
  provider: "acme"
  email: "ops@example.com"            # the ACME account contact

artifact:
  url: "oci://ghcr.io/your-org/ml-deployment-toolkit"
  version: "latest"                   # "latest" or a pinned tag

registry:
  provider: "none"                    # Harbor lives on this cluster; nothing to proxy through

email:                                # transactional SMTP; credentials in .env
  host: "smtp.example.com"
  port: "587"
  from: "grafana@example.com"

alerting:                             # Grafana contact points
  email:
    to: "ops@example.com"
  telegram:
    chat_id: "0"                      # token in .env
```

A Tooling Cluster carries no `data`, no `app`, and no `toolkit_cc` — it is the thing other clusters point at.

**`cert.email` is the ACME account contact and nothing else.** It replaces the old `app.alert_email`, which despite its name only ever reached Let's Encrypt. Alert destinations are `alerting:`.

## A Hub, annotated

From `environments/mlf-lab1-sw1/config.yaml.sample`. The `cluster`, `infra`, `dns`, `cert`, and `artifact` sections have the same shape as above; what a Hub adds:

```yaml
version: 1

cluster:
  name: "my-switch"
  role: "env"
  vip: "192.168.0.214"
  lb_ipam:
    range: "192.168.0.215-192.168.0.217"   # three addresses

template: "tps-10"                    # config/templates/env/tps-10.yaml

# Supporting services — each independent, each may point anywhere.
# See "The toolkit-cc shorthand" below for the one-value alternative.
registry:
  provider: "harbor"
  url: "harbor.int.cc1.lab1.example.com"

object_storage:
  provider: "s3"
  endpoint: "https://s3.int.cc1.lab1.example.com"
  bucket: "backups"
  region: "us-east-1"

observability:
  provider: "urls"
  loki_url: "https://loki.int.cc1.lab1.example.com/loki/api/v1/push"
  mimir_url: "https://thanos.int.cc1.lab1.example.com/api/v1/receive"
  tempo_url: "https://tempo.int.cc1.lab1.example.com/v1/traces"

data:
  mysql:
    mode: "in-cluster-managed"
  kafka:
    mode: "in-cluster-managed"
  mongodb:
    mode: "in-cluster-managed"
  redis:
    mode: "in-cluster-managed"

email:                                # required — MCM/Kratos send activation mail
  host: "smtp.example.com"
  port: "587"
  from: "grafana@example.com"

alerting:
  email:
    to: "ops@example.com"
  telegram:
    chat_id: "0"

app:
  api_type: "fspiop"                  # fspiop | iso20022 — set once, see below
  hub:
    participant_name: "Hub"
    admin_email: "hub-admin@example.com"
    onboarding:
      funds_in: "1000000"             # initial settlement-account deposit
      net_debit_cap: "500000"         # transfers blocked beyond this
```

**`app.api_type` is set once.** It selects the FSPIOP message dialect. Switching it on a running Hub breaks in-progress transfers, and every participant and simulator must use the same dialect.

**`app.hub.admin_email` is the HubOps login for MCM and the Finance Portal.** The matching password is generated — read it with `make secrets` ([Secrets](#secrets)).

Without `toolkit_cc`, a Hub is standalone: it pulls the artifact straight from a public registry, keeps no off-cluster backups, and ships no telemetry. That is a valid deployment, not a broken one.

## Deployment templates

`template` names a file under `config/templates/<role>/`. Templates are provider-independent: they declare **node groups** and the service tuning that must scale with them.

| Role | Templates |
|------|-----------|
| Tooling Cluster (`cc`) | `small`, `medium` |
| Hub (`env`) | `tps-1`, `tps-10` |
| Platform-only (`base`) | `small` |

Hub templates are named for the transactions-per-second they are sized to sustain. Rationale in [ADR-012](../../architecture/decisions/012-tps-sizing-profiles.md); the current two-layer shape in [ADR-015](../../architecture/decisions/015-two-stack-capability-config.md).

A node group expands to `count` nodes named `<cluster>-<group>-<index>`:

```yaml
node_groups:
  - name: w
    class: worker-general      # workload class — labels, taints, Talos patches
    count: 3
    cores: 6
    memory: 12288              # MB
    disks: [64, 64]            # GB
    placement: [pg-3, pg-2, pg-1]
```

`placement` is index-aligned — node `i` lands on `placement[i]`, wrapping when the list is shorter than `count`. The `pg-N` names are abstract; `infra.<provider>.placement` in `config.yaml` maps them to physical Proxmox nodes. Provide a mapping for every group the template references.

The concrete machine behind a workload class comes from `config/templates/mappings/<provider>.yaml` — VM defaults on Proxmox, instance types on AWS and DigitalOcean. That file is distribution-maintained; adopters do not edit it.

## Data modes

Each of the Hub's four stores is chosen independently, in `data.<store>.mode`:

| Mode | Behaviour |
|------|-----------|
| `in-cluster-managed` (default) | Operators and CRs deploy from the artifact, endpoints derived, sizing from the template |
| `external-unmanaged` | The adopter supplies `host` (and optionally `port`) and credentials; that store's `env-data` Kustomization is **not** created and the toolkit reconciles nothing |
| `external-managed` | Schema-reserved. Terraform rejects it today with an explicit message — not yet implemented |

```yaml
data:
  mysql:
    mode: "external-unmanaged"
    host: "mysql.lab1.example.com"
    port: "3306"
  kafka:
    mode: "in-cluster-managed"
```

Mixing is legitimate — external MySQL with in-cluster Kafka is a supported combination. An `external-unmanaged` store without a `host` fails at plan time.

Credentials for an external store come from `.env` under the same UPPER_CASE name the toolkit would otherwise generate (`MYSQL_ROOT_PASSWORD` and friends) — see [Secrets](#secrets). Backups of an external store are the adopter's responsibility; the toolkit's backup path covers in-cluster stores only.

## The toolkit-cc shorthand

The registry, object-storage, and observability endpoints are normally written out, as in the Hub example above — the values stay visible and independent of anything this distribution decides.

When a Tooling Cluster deployed by *this* toolkit backs all of them, the same five endpoints can be derived from its domain instead:

```yaml
toolkit_cc:
  domain: "cc1.lab1.example.com"
```

Then set `provider: toolkit-cc` on whichever capabilities should use it. The toolkit owns that URL scheme, so it derives them:

| Capability | Derived endpoint |
|------------|------------------|
| `registry` | `harbor.int.<domain>` |
| `object_storage` | `https://s3.int.<domain>` |
| `observability` (metrics) | `https://thanos.int.<domain>/api/v1/receive` |
| `observability` (logs) | `https://loki.int.<domain>/loki/api/v1/push` |
| `observability` (traces) | `https://tempo.int.<domain>/v1/traces` |

Setting `provider: toolkit-cc` on any capability without also setting `toolkit_cc.domain` fails at plan time, saying exactly that.

The shorthand saves transcription and makes a domain change one edit instead of five, but it is a convenience rather than a contract: it assumes the route layout this distribution currently gives a Tooling Cluster, and nothing validates that assumption at plan time. Prefer the explicit endpoints when the Hub and Tooling Cluster are upgraded on separate schedules, or when anything other than a toolkit-deployed Tooling Cluster provides a service. The resolved configuration is identical either way.

The presets are per capability, not all-or-nothing — a Hub may pull images through the Tooling Cluster's Harbor while pushing telemetry to an external stack:

```yaml
registry:
  provider: "toolkit-cc"
observability:
  provider: "urls"
  mimir_url: "https://metrics.example.com/api/v1/receive"
  loki_url: "https://logs.example.com/loki/api/v1/push"
  tempo_url: "https://traces.example.com/v1/traces"
```

Likewise `object_storage.provider: s3` with an explicit `endpoint` points backups at any S3-compatible store.

**The Tooling Cluster must be reachable before the Hub deploys** — deriving a URL does not make it answer. See [Tooling Cluster → Hand-off to the Hub](tooling-cluster.md#hand-off-to-the-hub).

## Secrets

Secrets split in two, and the split is the point: **`.env` holds only what the toolkit cannot generate.**

**Generated by Terraform.** Every internal service password — MySQL and MongoDB accounts, the Ory and MCM databases, MinIO, Harbor, Grafana, the hub admin, the OIDC client and Kratos/Hydra signing secrets. Around twenty values on a Hub, three on a Tooling Cluster. They are created in the config stack, written into `cluster-secrets`, and never typed by anyone.

Read them back on demand:

```bash
make secrets ENV=<env>
```

That is also how a Hub's `.env` gets its Tooling Cluster credentials: `make secrets ENV=<cc-env>` prints `harbor_admin_password` and `minio_root_password`, which become the Hub's `OCI_PROXY_PASSWORD` and `BACKUP_S3_SECRET_KEY`.

**Supplied in `.env`.** Only credentials that exist outside the deployment:

| Variable(s) | Needed when |
|-------------|-------------|
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`, `PROXMOX_VE_SSH_PASSWORD` | `infra.provider: proxmox` |
| `DIGITALOCEAN_TOKEN` / `CLOUDFLARE_API_TOKEN` / `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_REGION` | the chosen `dns.provider` |
| `OCI_REPO_USERNAME`, `OCI_REPO_PASSWORD` | private artifact registry, or publishing one |
| `OCI_PROXY_USERNAME`, `OCI_PROXY_PASSWORD` | `registry.provider` is `toolkit-cc` or `harbor` |
| `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY` | `object_storage.provider` is `toolkit-cc` or `s3` |
| `SMTP_USER`, `SMTP_PASSWORD` | `email:` is configured |
| `TELEGRAM_BOT_TOKEN` | `alerting.telegram` is configured |

The SMTP host, port, sender, alert recipient, and Telegram chat ID are **not** secrets — they live in `config.yaml` under `email:` and `alerting:`.

```bash
$EDITOR environments/<env>/.env
```

Three things worth knowing:

- **Any generated password can be overridden** by setting its UPPER_CASE name in `.env` — `MYSQL_ROOT_PASSWORD`, `HARBOR_ADMIN_PASSWORD`, and so on. This is how an `external-unmanaged` data store receives its credentials, and how an environment migrated from an older layout keeps the passwords it already has.
- **Proxmox variables are read natively** by the provider. `PROXMOX_VE_*` are used as-is.
- **Generated passwords live in the config stack's Terraform state** (`artifacts/<env>/terraform/config.tfstate`) as well as in the cluster. Losing both loses the passwords — see [Disaster recovery](../recover/disaster-recovery.md#what-the-adopter-must-keep).

## Helm value overrides

The adopter can override the platform's Helm values for **any** chart the distribution ships, without forking anything. Drop a file named for the HelmRelease in `values/`:

```
environments/<env>/values/
  mojaloop.yaml
  grafana.yaml
  loki.yaml
```

Each file becomes a `<name>-values-override` ConfigMap, layered over the platform defaults through the HelmRelease's `valuesFrom` as an optional reference — a missing file changes nothing. Merge order is chart defaults, then platform values, then the environment's file. The name must match the HelmRelease, not the chart's upstream name: `psmdb-operator.yaml`, not `percona-mongodb.yaml`.

**Override files are templated**, with the same `${...}` syntax the artifact's manifests use — the config stack expands them before writing the ConfigMap, because Flux does not substitute inside a ConfigMap it did not render:

```yaml
ingress:
  hosts:
    - "example.${domain}"
replicas: ${cl_service_replicas}
```

Available variables are the cluster identity (`cluster_name`, `domain`), the resolved telemetry sinks (`loki_url`, `mimir_url`, `tempo_url`), and every key from the template's `app:`, `data:`, and `cc:` sections. **Credentials are deliberately not available** — override files are for values, not secrets.

Two consequences of real templating:

- **An unknown `${name}` fails the apply**, it is not left alone. That is the error to expect from a typo.
- **A literal `${` must be escaped as `$${`** — relevant when a chart value itself carries shell or Helm-adjacent syntax.

Override files belong to the config stack, so applying them is the fast path:

```bash
make apply-config ENV=<env>
```

Seconds, no infrastructure plan, and Flux picks the change up on its next reconcile. This is configuration, not customization — changing the distribution itself is the [Integrator](../../integrator/index.md) guide.

## Validating

```bash
make validate ENV=<env>
```

This checks, in order: `config.yaml` against the JSON Schema, the selected template against the template schema, the provider mapping against the mapping schema, and then `terraform validate` on both stacks (skipped until `make init` has run). Cross-field rules the schema cannot express — `cluster.name` matching the directory, `toolkit-cc` without a domain, an `external-unmanaged` store without a host — are Terraform preconditions and surface at plan time.

Next: [Deployment](deployment.md).
