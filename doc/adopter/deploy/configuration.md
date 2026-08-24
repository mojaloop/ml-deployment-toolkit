# Configuration

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Configuration

**Audiences:** adopter (deploy)

An environment is described by a handful of files in its own directory: `config.yaml` for what the deployment is, `.env` for the credentials it needs from the outside world, `placement.yaml`, `proxmox/proxmox.yaml`, and `talos.yaml` for the facts about the hardware it lands on, and the optional `values/`, `patches/`, and `talos/` directories for reaching past all of them. Everything specific to a deployment lives in these; the adopter never edits the distribution.

- [Vocabulary](#vocabulary)
- [Environment layout](#environment-layout)
- [config.yaml](#configyaml)
- [A Tooling Cluster, annotated](#a-tooling-cluster-annotated)
- [A Hub, annotated](#a-hub-annotated)
- [Deployment templates](#deployment-templates)
- [Data modes](#data-modes)
- [Supporting services](#supporting-services)
- [Secrets](#secrets)
- [Helm value overrides](#helm-value-overrides)
- [Manifest patches](#manifest-patches)
- [Validating](#validating)

## Vocabulary

Configuration values match the documentation's names: `role: tooling` deploys a Tooling Cluster, `role: hub` deploys a Hub. The one remaining translation is **Participant**, which appears in code and APIs as `dfsp` / `DFSP_ID`.

> **"Hub" is the Mojaloop hub** — the switch this cluster runs — not the hub of a hub-and-spoke fleet topology. The central shared-services cluster in this toolkit is the Tooling Cluster.

## Environment layout

Each environment is a directory under `../environments/` — a **sibling of the toolkit clone**, not inside it — and each environment is its own private git repository. `ENV=` selects it: `make` runs from the clone root and reads `$(ENVIRONMENTS_ROOT)/<name>/`, where `ENVIRONMENTS_ROOT` defaults to `../environments` (override it, like `ARTIFACTS_ROOT`, for a non-standard layout).

```
<project root>/
  ml-deployment-toolkit/     # the clone — pristine, read-only, checked out at a release tag
  environments/
    my-cc/                   # adopter-owned, its own git repository
      config.yaml            # what the deployment is
      .env                   # external credentials — never committed anywhere
      placement.yaml         # placement groups -> physical nodes
      talos.yaml             # Talos node OS facts — nameservers, NTP
      talos/                 # optional per-pool Talos machine-config fragments — <pool>.yaml
      proxmox/
        proxmox.yaml         # network bridge and storage pools
      values/                # optional Helm overrides — <namespace>/<release>.yaml
      patches/               # optional manifest patches — <kustomization>.yaml
  artifacts/
    my-cc/
      state/                 # Terraform state — secret-bearing, the adopter's own backup
      plans/                 # saved plans — disposable
```

Environments are fully independent — their own repository, config, secrets, and Terraform state. One clone manages any number of them. A Tooling Cluster and its Hubs are separate environments, each deployed with its own `make plan-apply ENV=<name>`.

**The clone stays pristine.** The adopter never commits to it — editing it is forking public software, and `make check-pristine` reports a dirty tree or an untagged checkout ([Validating](#validating)). Upgrading the clone is a `git checkout` of the next release tag, never a rebase.

**The environment repository holds everything except `.env`.** Commit `config.yaml`, `placement.yaml`, `talos.yaml`, `talos/`, `proxmox/proxmox.yaml`, `values/`, and `patches/`; the `.gitignore` shipped with the sample environments excludes `.env`, and it must never be committed anywhere — it holds the external credentials.

Beside `config.yaml`, three small files carry the facts about the adopter's hardware, each schema-validated by `make validate`:

```yaml
# placement.yaml — which physical node each template placement group lands on
version: 1
placement:
  pg-1: "pve-node-1"
# Optional: override the template's node pools BY NAME — partial keys inherit
# the rest, enabled: false drops a default pool, an unknown name adds one.
pools:
  w:
    count: 4
```

```yaml
# proxmox/proxmox.yaml — single-consumer overrides of the provider defaults
version: 1
network_bridge: "vmbr0"
storage:
  disks: "local-lvm"
  images: "local"
  snippets: "local"
```

```yaml
# talos.yaml — Talos node OS facts, read only by the on-prem machine-config path
version: 1
nameservers: ["8.8.8.8", "1.1.1.1"]
ntp_servers: ["time.cloudflare.com"]
```

Per-pool Talos machine-config fragments go in `talos/<pool>.yaml`, where `<pool>` is a pool name from the template's `placement.yaml` — each fragment is merged into every node of that pool, after the template's own fragment for the same pool. Talos merge rules differ from Helm's: maps merge, **lists append** — state only the additions, and remove entries with `$patch: delete`.

**`cluster.name` defaults to the directory name** and can be omitted for a new deployment, so identity is normally one value rather than two. Set it explicitly only to keep a name a cluster already has — it is durable identity, becoming the external-dns record owner, the Vault backup prefix, and the VM name prefix, so changing it on a live cluster orphans its DNS records and forces VM replacement.

State and generated artifacts land under `../artifacts/<env>/` — a sibling of both repositories, tracked by neither. The split inside it is the backup boundary: `state/` holds the Terraform state — non-regenerable and secret-bearing, created mode `0700` by `make init`, with its own backup policy — while `plans/` holds saved plans, which are disposable. See [System overview](../../architecture/system-overview.md#configuration-tiers) and [Backups](../recover/backup.md#terraform-state).

> **Start from the reference environments.** The clone carries `examples/environments/hub/` and `examples/environments/tooling/`, each holding `config.yaml.sample`, `.env.sample`, `placement.yaml.sample`, `talos.yaml.sample`, and `proxmox/proxmox.yaml.sample` — the Hub sample also ships performance-test samples (`perf-topology.yaml.sample`, `perf-scenarios/`). From the clone root:
>
> ```bash
> cp -R examples/environments/hub ../environments/<env>
> ```
>
> Strip the `.sample` suffixes, edit, then `git init` the new directory as its own repository.

## config.yaml

`config.yaml` is a flat list of sections, one per **capability** — one dimension of the deployment. Nine sections are required: `version`, `cluster`, `template`, `infra`, `dns`, `cert`, `registry`, `object_storage`, and `observability`. The three supporting-service sections are required even when off — `enabled: false` is stated, never implied by omission.

| Section | Required | Keys | Default |
|---------|:---:|---------|---------|
| `version` | yes | `1` | — |
| `dtk_version` | no | the exact DTK release tag this environment is written against, e.g. `v0.19.0` | none — when set, the plan fails unless the clone is checked out at that tag |
| `cluster` | yes | `name`, `role`, `vip`, `lb_ipam.pools` (per-gateway `lan`/`wan`), `flux.version` | Flux `2.9.3` |
| `template` | yes | a name under `config/templates/<provider>/<role>/` | — |
| `infra` | yes | `provider` (`proxmox` \| `aws` \| `digitalocean`), `aws.region`, `digitalocean` — placement, bridge, storage, and the Talos node OS facts live in the sidecar files `placement.yaml`, `proxmox/proxmox.yaml`, and `talos.yaml`, not here | — |
| `dns` | yes | `provider` (`digitalocean` \| `cloudflare` \| `route53`), `domain` | — |
| `cert` | yes | `email` (ACME contact), `server` (ACME directory URL) — both required, neither defaulted | — |
| `artifact` | no | `url`, `version` (a pinned `vX.Y.Z` tag — `latest` is rejected by the schema), `active` — the gitops OCI artifact Flux reconciles | none — no Kustomizations created; `active` defaults to true once `url` is set |
| `registry` | yes | `enabled` + `url`; on a Tooling Cluster also `robots[]` | — |
| `object_storage` | yes | `enabled` + `endpoint`, `bucket`, `region`; on a Tooling Cluster also `buckets[]` | — |
| `observability` | yes | `enabled` + `loki_url`, `mimir_url`, `tempo_url`; on a Tooling Cluster also `ingest_users[]` | — |
| `data` | no (Hub only) | per store: `in-cluster-managed`, `external-unmanaged`, `external-managed` (reserved) + `host`/`port` for external modes | `in-cluster-managed` |
| `email` | no | SMTP relay for transactional mail — `host`, `port`, `from` | off |
| `alerting` | no | Grafana contact points — `email.to`, `telegram.chat_id` | off |
| `app` | no (Hub only) | `api_type`, `hub.{participant_name, admin_email, onboarding.{funds_in, net_debit_cap}}` | `fspiop`, `Hub` |

Three fields decide the shape of everything else:

| Field | Effect |
|-------|--------|
| `cluster.role` | Which Kustomizations deploy — `tooling` or `hub` — and, with `infra.provider`, which template directory is read |
| `template` | Node pools, machine sizing, and the template's `values/`, `patches/`, and `talos/` overlays |
| `artifact.version` | The exact platform release the cluster runs — always a pinned tag, bumped deliberately ([Upgrading](upgrading.md)) |

Sample files carry a `# yaml-language-server: $schema=` header on the first line. An editor with the YAML language server gives autocomplete and inline errors against the real schema — keep that line when copying.

**Address counts differ by role.** A Tooling Cluster needs two LB addresses; a Hub needs four, adding the FSPIOP endpoint and the machine-API gateway. See [Networking](../../architecture/networking.md#load-balancer-addresses).

## A Tooling Cluster, annotated

From `examples/environments/tooling/config.yaml.sample`:

```yaml
# yaml-language-server: $schema=../../config/schemas/environment.schema.json
version: 1

cluster:
  name: "my-cc"                       # optional — defaults to the directory name
  role: "tooling"                          # tooling | hub | bare
  vip: "192.168.0.210"                # Kubernetes API floating IP (on-prem only)
  lb_ipam:
    pools:                            # one single-IP pool per gateway
      gw-int:
        lan: "192.168.0.211"
      gw-ext:
        lan: "192.168.0.212"

template: "medium"                    # config/templates/proxmox/tooling/medium/

infra:
  provider: "proxmox"                 # proxmox | aws | digitalocean
  # Provider infra facts live beside this file, not here:
  #   placement.yaml       — placement groups -> physical nodes
  #   proxmox/proxmox.yaml — network bridge, storage pools
  # Talos node OS facts (nameservers, NTP) live in talos.yaml beside this file.

dns:
  provider: "route53"                 # digitalocean | cloudflare | route53
  domain: "cc1.lab1.example.com"

cert:
  email: "ops@example.com"            # the ACME account contact
  server: "https://acme-v02.api.letsencrypt.org/directory"   # selects the CA

artifact:
  url: "oci://ghcr.io/your-org/ml-deployment-toolkit"
  version: "v0.19.0"                  # a pinned vX.Y.Z tag — "latest" is rejected

registry:
  enabled: false                      # Harbor lives on this cluster; nothing to proxy through

object_storage:
  enabled: false                      # MinIO lives here; this cluster is the backup target
  buckets:                            # extra buckets to serve — see below
    - name: "my-switch-backups"

observability:
  enabled: false                      # the telemetry backend lives here too
  ingest_users:                       # ingest accounts to serve — see below
    - name: "my-switch"

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

A Tooling Cluster carries no `data` and no `app` — it is the thing other clusters point at. It still declares all three supporting-service sections with `enabled: false`, since each is required and off is stated rather than implied by omission.

**`object_storage.buckets` declares what this cluster serves** — the reverse of the section's meaning on a Hub, where it names the backup target to consume. Each declared bucket is created in MinIO alongside the system buckets (`harbor`, `backups`, `thanos`, `loki`, `tempo`, which always exist and cannot be re-declared) and gets a generated user scoped to that one bucket: the access key is the bucket name, the secret key is a generated secret named `MINIO_BUCKET_<NAME>_SECRET_KEY` — with hyphens and dots in `<name>` becoming underscores, so bucket `my-switch-backups` yields `MINIO_BUCKET_MY_SWITCH_BACKUPS_SECRET_KEY`. The convention is one bucket per Hub, named `<hub cluster.name>-backups`, so no Hub's credentials can touch another Hub's backups. Creation is additive and one-way — removing an entry stops managing the bucket but never deletes data.

One rotation caveat: the MinIO provisioning job creates users but never updates an existing user's secret key. Pinning a new `MINIO_BUCKET_<NAME>_SECRET_KEY` in `.env` after the user exists — or removing a bucket entry and re-declaring it later, which regenerates its key while the MinIO user survives with the old one — leaves `make secrets` printing a key MinIO does not have. To rotate, delete the user in MinIO first; the next reconcile recreates it with the current key.

**`cert.email` is the ACME account contact and nothing else.** Alert destinations are `alerting:`.

**`cert.server` selects the certificate authority and is required.** It sets the `server` of the `acme-prod` ClusterIssuer — the one the Gateways annotate, so it is the URL every platform certificate is actually issued from. There is no provider name to choose: the directory URL is the CA's identity, stated outright rather than defaulted ([ADR-016](../../architecture/decisions/016-generic-acme-ca.md)).

```yaml
cert:
  email: "ops@example.com"
  server: "https://dv.acme-v02.api.pki.goog/directory"
```

| CA | `cert.server` | EAB |
|----|---------------|-----|
| Let's Encrypt | `https://acme-v02.api.letsencrypt.org/directory` | not used |
| Google Trust Services | `https://dv.acme-v02.api.pki.goog/directory` | required |
| ZeroSSL | `https://acme.zerossl.com/v2/DV90` | required |
| SSL.com | `https://acme.ssl.com/sslcom-dv-rsa` | required |

**Every public CA except Let's Encrypt requires External Account Binding** — a keyID and an HMAC key tying the ACME account to the adopter's existing account with that CA. Put both in `.env`; setting them is what switches EAB on, and there is no separate toggle:

```bash
ACME_EAB_KEY_ID="..."
ACME_EAB_HMAC_ENCODED="..."
```

Obtain the pair from the CA: `gcloud publicca external-account-keys create` for Google Trust Services, the REST API for ZeroSSL, the web dashboard for SSL.com. **Paste the HMAC key exactly as given** — it is already base64url, and encoding it a second time produces `Invalid MAC on JWS request` at issuance. Should a CA document a different format, convert with:

```bash
echo -n '<key>' | base64 -w0 | tr '+/' '-_' | tr -d '='
```

Setting one of the two without the other fails at `make plan-config`, before anything reaches the cluster. Note that `make validate` will not catch it — the schema is handed only `config.yaml` and never sees `.env`.

Two caveats when changing CA on a running cluster. The ACME account key is named after a hash of `cert.server`, so switching URL correctly forces re-registration rather than silently reusing the old account — but the previous account-key Secret is left behind and can be deleted by hand. And not every CA issues wildcards on its free tier: SSL.com's free DV covers a single domain plus `www`, which cannot serve the `*.int` / `*.ext` Gateway certificates this toolkit relies on.

## A Hub, annotated

From `examples/environments/hub/config.yaml.sample`. The `cluster`, `infra`, `dns`, `cert`, and `artifact` sections have the same shape as above; what a Hub adds:

```yaml
version: 1

cluster:
  name: "my-switch"
  role: "hub"
  vip: "192.168.0.214"
  lb_ipam:
    pools:                            # a hub serves all four gateways
      gw-int:
        lan: "192.168.0.215"
      gw-ext:
        lan: "192.168.0.216"
        wan: "203.0.113.10"           # optional: border-DNAT outside IP, becomes the published DNS target
      gw-extapi:
        lan: "192.168.0.217"
      gw-intapi:
        lan: "192.168.0.218"

template: "tps-10"                    # config/templates/proxmox/hub/tps-10/

# Supporting services — each independent, each may point anywhere.
# All three are required; endpoints are stated outright, never derived.
registry:
  enabled: true
  url: "harbor.int.cc1.lab1.example.com"

object_storage:
  enabled: true
  endpoint: "https://s3.int.cc1.lab1.example.com"
  bucket: "my-switch-backups"         # declared on the Tooling Cluster, one per Hub
  region: "us-east-1"

observability:
  enabled: true
  # Authenticated push (basic auth, OBS_INGEST_* in .env; TLS verified)
  loki_url: "https://loki.ext.cc1.lab1.example.com/loki/api/v1/push"
  mimir_url: "https://thanos.ext.cc1.lab1.example.com/api/v1/receive"
  tempo_url: "https://tempo.ext.cc1.lab1.example.com/v1/traces"

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

With all three supporting-service sections at `enabled: false`, a Hub is standalone: it pulls the artifact straight from a public registry, keeps no off-cluster backups, and ships no telemetry. That is a valid deployment, not a broken one.

## Deployment templates

`template` names a directory under `config/templates/<provider>/<role>/` — the directory read is `config/templates/<provider>/<role>/<name>/`, selected by `infra.provider`, `cluster.role`, and `template` together. Each provider carries its own complete set: a template is a full overlay for that provider, with no knobs or conditionals inside it. There are **no template-supplied substitution variables**: `template.yaml` carries identity only (`version`, `description`), the topology lives in the template's `placement.yaml`, and any service tuning that must scale with the topology ships as ordinary `values/<namespace>/<release>.yaml` and `patches/<kustomization>.yaml` overlays inside the template directory — the same file kinds the environment uses, merged between the distribution's defaults and the environment's own overrides. Per-pool Talos machine-config fragments sit in the template's `talos/`.

| Role | Templates |
|------|-----------|
| Tooling Cluster (`tooling`) | `dev`, `small`, `medium` |
| Hub (`hub`) | `dev`, `tps-1`, `tps-10` |
| Platform-only (`bare`) | `small` |

Hub templates are named for the transactions-per-second they are sized to sustain. Rationale in [ADR-012](../../architecture/decisions/012-tps-sizing-profiles.md); the current two-layer shape in [ADR-015](../../architecture/decisions/015-two-stack-capability-config.md).

The template's `placement.yaml` declares the node pools. A pool expands to `count` nodes named `<cluster>-<pool>-<index>`:

```yaml
node_groups:
  - name: w
    class: worker-general      # workload class — Talos machine type and patches
    count: 3
    cores: 6
    memory: 12288              # MB
    disks: [64, 64]            # GB
    placement: [pg-3, pg-2, pg-1]
    tags: [lab1]               # optional — extra Proxmox/cloud tags on every node
    taints: []                 # optional — taints this pool declares for itself
```

Every node carries the tags `ml` and the cluster name; `tags` on a group adds to that list. `placement` is index-aligned — node `i` lands on `placement[i]`, wrapping when the list is shorter than `count`. The `pg-N` names are abstract; the environment's `placement.yaml` maps them to physical Proxmox nodes ([Environment layout](#environment-layout)). Provide a mapping for every group the template references — an unmapped group fails the plan.

**A pool's name is its placement contract.** Each node is labelled mechanically as `<P_NODE_ROLE_LABEL_KEY>=<pool name>` — a pool named `kafka` labels its nodes `node-role=kafka`, and nothing else assigns node labels. A pool that should repel other workloads declares its own taints in `taints:` (`{key, value, effect}` entries). The distribution's manifests reference pools with **soft affinity**, so a template without a given pool still schedules — the workload lands somewhere rather than staying Pending — and `check-placement` (environment-aware) fails any hard selector naming a pool outside the environment's effective pool set: the template's pools, minus those the environment's `placement.yaml` disables, plus those it adds.

### The provider interface: `params.yaml`

Beside each provider's templates sits `config/templates/<provider>/params.yaml`, in two parts:

- **`params`** — the provider interface: the `P_*` symbols the shared gitops manifests may reference — `P_GATEWAY_CLASS`, `P_STORAGE_CLASS`, `P_NODE_ROLE_LABEL_KEY`, `P_L2_INTERFACE_REGEX`, `P_KUBE_API_HOST`, `P_KUBE_API_PORT`. They resolve from `params.yaml` **only**; `config.yaml` can neither define nor shadow a `P_*` symbol, and a check enforces it. The GatewayClass is one of them: the former `cluster.gateway_class_name` key is gone, replaced by the provider's `P_GATEWAY_CLASS`.
- **`infra`** — Terraform-consumed provider configuration: VM defaults on Proxmox, instance types on AWS and DigitalOcean.

The file is distribution-maintained. Editing it is forking the distribution, and `make check-pristine` reports it. The `aws` and `digitalocean` interface values are marked unvalidated in the files themselves — second-provider validation is pending.

## Data modes

Each of the Hub's four stores is chosen independently, in `data.<store>.mode`:

| Mode | Behaviour |
|------|-----------|
| `in-cluster-managed` (default) | Operators and CRs deploy from the artifact, endpoints derived, sizing from the template |
| `external-unmanaged` | The adopter supplies `host` (and optionally `port`) and credentials; that store's `hub-data` Kustomization is **not** created and the toolkit reconciles nothing |
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

## Supporting services

`registry`, `object_storage` and `observability` are all required sections, and each takes `enabled`. When enabled, its endpoints are written out in full — nothing is derived from a domain and nothing is defaulted, so what the file says is what the cluster is pointed at ([ADR-017](../../architecture/decisions/017-explicit-capability-endpoints.md)).

The three are independent — a Hub may pull images through a Tooling Cluster's Harbor while pushing telemetry to an external stack, and back up to a third place entirely:

```yaml
registry:
  enabled: true
  url: "harbor.int.cc1.lab1.example.com"
object_storage:
  enabled: true
  endpoint: "https://s3.eu-west-2.amazonaws.com"
  bucket: "my-switch-backups"
  region: "eu-west-2"
observability:
  enabled: true
  mimir_url: "https://metrics.example.com/api/v1/receive"
  loki_url: "https://logs.example.com/loki/api/v1/push"
  tempo_url: "https://traces.example.com/v1/traces"
```

Enabling a capability without its endpoints fails at plan time, naming the section:

| Capability | Required when `enabled: true` |
|------------|-------------------------------|
| `registry` | `url` (no `oci://` prefix — it becomes a Talos registry mirror) |
| `object_storage` | `endpoint`, `bucket`, `region` |
| `observability` | `loki_url`, `mimir_url`, `tempo_url` |

`object_storage.bucket` and `region` are required rather than defaulted ([ADR-017](../../architecture/decisions/017-explicit-capability-endpoints.md)) — a missing value fails at plan time instead of at backup time.

Any S3-compatible endpoint works for `object_storage`, provided it speaks SigV4 with a static access key and presents a publicly-trusted certificate. A Tooling Cluster's MinIO and a native cloud endpoint are configured identically. Endpoints behind a private CA, and stores requiring path-style addressing, are not reachable by configuration today — the operators support both, but the toolkit does not yet expose the fields.

Setting `object_storage.enabled: false` disables backups structurally: PSMDB and PXC backups and PITR are switched off and the Vault snapshot CronJob is suspended. The switch-off is structural because PSMDB refuses to mark a cluster ready, and to create its app users, while PBM cannot reach its storage. Turning it back on later restarts the mongod pods, since PBM sidecars are added.

**A Tooling Cluster must be reachable before the Hub deploys** — writing its URL down does not make it answer. See [Tooling Cluster → Hand-off to the Hub](tooling-cluster.md#hand-off-to-the-hub).

## Secrets

Secrets split in two, and the split is the point: **`.env` holds only what the toolkit cannot generate.**

**Generated by Terraform.** Every internal service password — MySQL and MongoDB accounts, the Ory and MCM databases, MinIO, Harbor, Grafana, the hub admin, the OIDC client and Kratos/Hydra signing secrets. Around twenty values on a Hub, three on a Tooling Cluster. They are created in the config stack, written into `cluster-secrets`, and never typed by anyone.

Read them back on demand:

```bash
make secrets ENV=<env>
```

That is also how a Hub's `.env` gets its Tooling Cluster credentials: `make secrets ENV=<tooling-env>` prints one `HARBOR_ROBOT_<NAME>_SECRET` per robot declared under `registry.robots`, which becomes the Hub's `OCI_PROXY_PASSWORD` (its `OCI_PROXY_USERNAME` is `robot-<name>`), one `MINIO_BUCKET_<NAME>_SECRET_KEY` per bucket declared under `object_storage.buckets`, which becomes the Hub's `BACKUP_S3_SECRET_KEY` (its `BACKUP_S3_ACCESS_KEY` is the bucket name), and one `OBS_INGEST_<NAME>_PASSWORD` per account declared under `observability.ingest_users`, which becomes the Hub's `OBS_INGEST_PASSWORD` (its `OBS_INGEST_USERNAME` is the account name). In the generated names, hyphens and dots in `<NAME>` become underscores. A Tooling Cluster with nothing declared falls back to the shared credentials — `admin` / `HARBOR_ADMIN_PASSWORD` and `minioadmin` / `MINIO_ROOT_PASSWORD` — workable, but admin credentials in a Hub's `.env` are exactly what the scoped accounts exist to avoid.

**Supplied in `.env`.** Only credentials that exist outside the deployment:

| Variable(s) | Needed when |
|-------------|-------------|
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`, `PROXMOX_VE_SSH_PASSWORD` | `infra.provider: proxmox` |
| `DIGITALOCEAN_TOKEN` / `CLOUDFLARE_API_TOKEN` / `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_REGION` | the chosen `dns.provider` |
| `OCI_REPO_USERNAME`, `OCI_REPO_PASSWORD` | private artifact registry, or publishing one |
| `OCI_PROXY_USERNAME`, `OCI_PROXY_PASSWORD` | `registry.enabled` is true |
| `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY` | `object_storage.enabled` is true |
| `SMTP_USER`, `SMTP_PASSWORD` | `email:` is configured |
| `TELEGRAM_BOT_TOKEN` | `alerting.telegram` is configured |

The SMTP host, port, sender, alert recipient, and Telegram chat ID are **not** secrets — they live in `config.yaml` under `email:` and `alerting:`.

```bash
$EDITOR ../environments/<env>/.env
```

**`.env` is never committed anywhere.** The environment directory is a git repository, but the `.gitignore` shipped with the sample environments excludes `.env` — credentials live on the adopter's disk and in the adopter's own secure copy, nowhere else ([Disaster recovery → What the adopter must keep](../recover/disaster-recovery.md#what-the-adopter-must-keep)).

Four things worth knowing:

- **Any generated secret can be pinned** by setting its UPPER_CASE name in `.env` — `MYSQL_ROOT_PASSWORD`, `HARBOR_ADMIN_PASSWORD`, and so on. A non-empty value there is used verbatim and nothing is generated for that name; generation only kicks in for names that are absent or empty. This is how an `external-unmanaged` data store receives its credentials, and it is the migration path for an existing environment whose passwords must not rotate — see [Upgrading → Migrating an existing environment](upgrading.md#migrating-an-existing-environment).
- **The Ory signing secrets are pinnable too.** `KRATOS_SECRETS_CIPHER`, `KRATOS_SECRETS_COOKIE`, `KRATOS_SECRETS_CSRF_COOKIE`, `KRATOS_SECRETS_DEFAULT`, `HYDRA_SECRETS_SYSTEM`, and `HYDRA_SECRETS_COOKIE` behave like the passwords. They matter more than most: rotating `KRATOS_SECRETS_CIPHER` makes stored credential and recovery material undecryptable, and rotating `HYDRA_SECRETS_SYSTEM` invalidates every issued token and consent grant.
- **Proxmox variables are read natively** by the provider. `PROXMOX_VE_*` are used as-is.
- **Generated passwords live in the config stack's Terraform state** (`../artifacts/<env>/state/config.tfstate`) as well as in the cluster. Losing both loses the passwords — see [Disaster recovery](../recover/disaster-recovery.md#what-the-adopter-must-keep).

## Helm value overrides

The adopter can override the platform's Helm values for **any** chart the distribution ships, without forking anything. Drop a file at `values/<namespace>/<release>.yaml`, where `<namespace>` is the HelmRelease's target namespace and `<release>` is its name — the path is the binding, and the file body is plain Helm values with no header:

```
../environments/<env>/values/
  mojaloop/mojaloop.yaml
  observability/grafana.yaml
  observability/loki.yaml
```

Every HelmRelease's `valuesFrom` chain ends with the same three-layer tail of optional entries — a ConfigMap named `<targetNamespace>-<release>-values-template` (the selected template's tuning), then a ConfigMap and a Secret both named `<targetNamespace>-<release>-values-override` (the adopter's file). The tail is generated mechanically by `tools/generate-valuesfrom.sh`, never hand-written, and its completeness is verified by `tools/checks/check-valuesfrom.sh` (`make check`). The adopter's file becomes one of the two override objects, so a missing file changes nothing. The path must match the HelmRelease and its target namespace, not the chart's upstream name: `values/hub-system/psmdb-operator.yaml`, not `percona-mongodb.yaml`.

The same `values/<namespace>/<release>.yaml` path suffix names a release's values at every layer — the distribution's defaults at `gitops/<layer>/values/<namespace>/<release>.yaml`, the template's tuning at `config/templates/<provider>/<role>/<name>/values/<namespace>/<release>.yaml`, and the adopter's override in the environment — so diffing an override against the layer beneath it is a direct path comparison.

**The adopter's file is merged last, so it wins** ([ADR-022](../../architecture/decisions/022-helm-values-layering.md)). No HelmRelease uses inline `spec.values`; the distribution's own values ship as a ConfigMap listed *first* in `valuesFrom`, and the tail follows. Flux merges `valuesFrom` entries in order, later overwriting earlier, so the effective precedence is chart defaults → distribution values → template values → the adopter's file. Setting a key the distribution also sets is the normal case, and it takes effect. One merge rule to remember: maps merge, **lists replace** — overriding one element of a list means restating the whole list.

**Override files are templated**, with the same `${UPPER_SNAKE}` token syntax the artifact's manifests use — the config stack expands them at apply time, because Flux does not substitute inside a ConfigMap it did not render:

```yaml
ingress:
  hosts:
    - "example.${DOMAIN}"
```

Available tokens are exactly the substitution parameters derived from `config.yaml` and `.env` — the cluster identity (`${CLUSTER_NAME}`, `${DOMAIN}`), the resolved telemetry sinks (`${LOKI_URL}`, `${MIMIR_URL}`, `${TEMPO_URL}`), the other capability-derived keys, and the secret names — plus the provider interface's `P_*` symbols. Templates supply no tokens of their own: a template tunes by shipping its own values and patches files, not by defining variables, and what was once a template variable is now a literal default in the distribution's values ([Deployment templates](#deployment-templates)).

### Substitution rules

The same rules hold everywhere a `${...}` token appears — in the artifact's manifests, which Flux substitutes in-cluster from `cluster-config` and `cluster-secrets`, and in the environment's `values/` and `patches/` files, which Terraform templates at apply time:

- **Only bare `${UPPER_SNAKE}`.** No operators or inline defaults (`${VAR:-fallback}` is not supported by either engine), and no `%{ ... }` directives in environment-authored files.
- **An undefined token fails**, in both engines — Terraform errors at plan time; Flux fails the Kustomization rather than substituting an empty string. That is the error to expect from a typo.
- **A literal `${` is written `$${`** — the one escape that both engines honor.

That the two engines behave identically on these rules is not assumed: `check-engine-parity` (part of the `tools/checks/` suite) A/B-tests the same inputs through both and fails on any behavioural difference.

**Secrets choose the object.** A values file that references a key from `.env` — or any generated secret name, like `${MYSQL_ROOT_PASSWORD}` — is rendered as the **Secret** override, with the secret values available to it. A file with no secret reference becomes the ConfigMap and is templated **without** secrets, so a stray secret reference in a ConfigMap-destined file hard-fails at plan time instead of landing a credential in a ConfigMap. Patches never carry secrets — see [Manifest patches](#manifest-patches).

Override files belong to the config stack, so applying them is the fast path:

```bash
make apply-config ENV=<env>
```

Seconds, no infrastructure plan, and Flux picks the change up on its next reconcile. This is configuration, not customization — changing the distribution itself is the [Integrator](../../integrator/index.md) guide.

## Manifest patches

Helm value overrides reach every chart the distribution ships, which leaves out everything the distribution ships as a plain manifest — most importantly **the data layer**. Kafka, MySQL, MongoDB, and Redis are deployed as custom resources handed to their operators (`Kafka`, `PerconaXtraDBCluster`, `PerconaServerMongoDB`, `Redis`), not as charts. A `values/data/kafka.yaml` has nothing to attach to.

The shipped data-layer manifests carry their tuning — partition counts, buffer pools, volume sizes — as literal defaults, scaled per tier by the template's own `patches/` overlay. Changing any of it — JVM heap, replica counts, resource requests, MongoDB cache sizing, every Redis setting — is a patch. Drop a file named for the **Flux Kustomization** in `patches/` (flat, unlike the namespaced `values/` layout):

```
../environments/<env>/patches/
  hub-data-kafka.yaml
  hub-data-mysql.yaml
  hub-data-mongodb.yaml
  hub-data-redis.yaml
```

The name is the Kustomization, not the chart or the resource. The data layer's are `hub-data-<store>` for each `in-cluster-managed` store plus `hub-data-common`; the rest of the distribution is reachable by the same rule (`hub-app`, `tooling-observability`, `platform-config`, and so on), so this is not a data-layer-only mechanism.

### What goes in the file

A YAML **list**. Each element is either a partial resource, where kustomize infers the target from `apiVersion` / `kind` / `metadata.name`, or an explicit `{ target, patch }` entry carrying [JSON 6902](https://datatracker.ietf.org/doc/html/rfc6902) operations — the second form exists because a merge patch cannot remove a field:

```yaml
# ../environments/<env>/patches/hub-data-kafka.yaml

# Partial resource — merged into the shipped Kafka
- apiVersion: kafka.strimzi.io/v1
  kind: Kafka
  metadata:
    name: mojaloop-kafka
    namespace: data
  spec:
    kafka:
      jvmOptions:
        "-Xms": "2g"
        "-Xmx": "2g"
      config:
        log.retention.hours: 48

# Explicit target — required for a removal
- target:
    group: kafka.strimzi.io
    version: v1
    kind: KafkaNodePool
    name: dual-role
  patch: |
    - op: replace
      path: /spec/replicas
      value: 5
```

**Patches are templated**, exactly like values files: `${DOMAIN}`, `${CLUSTER_NAME}`, the telemetry URLs, and the other config-derived tokens expand at apply time, an unknown `${NAME}` fails the apply, and a literal `${` must be written `$${` ([Substitution rules](#substitution-rules)). One difference: **patches never carry secrets** — they are templated without the secret values, so a secret reference in a patch fails at plan time by design.

**The distribution's own patches apply first, then the template's, then the adopter's — so the adopter's win.** When `object_storage` is disabled the toolkit already patches the backup machinery off, and the selected template appends its per-tier tuning patches after that; the adopter's file is appended last, and kustomize applies patches in order.

### Semantics worth knowing

- **Maps merge, lists replace.** Adding `log.retention.hours` to `spec.kafka.config` leaves the other keys alone. Patching `spec.kafka.listeners` or a `tolerations` array replaces that array wholesale — kustomize has no schema for a CRD's lists and cannot merge them by key. To change one element, restate the whole list.
- **Patches run before substitution.** The order is kustomize build → the adopter's patch → `${...}` substitution from `cluster-config`. A patch can therefore introduce a new `$${VAR}` hole for Flux to fill, but it cannot read an already-substituted value.
- **A filename matching no Kustomization is ignored**, silently. Check the spelling against the list above if a patch appears to do nothing.
- **A patch matching no resource fails the whole Kustomization.** kustomize errors with `no matches for target`, that Kustomization goes NotReady, and because `hub-app` depends on every `hub-data-<store>`, the applications stop reconciling until it is fixed. This is the one way a patch is more dangerous than a values file, which can only break its own release. Nothing validates the target ahead of time — expect this error from a typo in a resource name, or after an upgrade renames a resource.
- **Operators reconcile their own fields.** Patching something Strimzi or Percona actively manages produces a drift loop rather than an error: the patch applies, the operator reverts it, Flux re-applies. Tune the fields the CR exposes as configuration, not the ones the operator computes.

Patches belong to the config stack, so the apply path is the same fast one:

```bash
make apply-config ENV=<env>
```

Deleting a patch file and re-applying reverts the field — the patch disappears from the rendered output and Flux applies the distribution's value back over it.

## Validating

```bash
make validate ENV=<env>
```

This checks, in order: `config.yaml` against the JSON Schema, the selected template's `template.yaml` and `placement.yaml` (`config/templates/<provider>/<role>/<name>/`) against theirs, the provider's `params.yaml` against the params schema, the environment's `placement.yaml`, `proxmox/proxmox.yaml`, and `talos.yaml` (when present) against theirs, and then `terraform validate` on both stacks (skipped until `make init` has run).

Three more gates sit beside it:

- **`make check`** runs the repo contract checks in `tools/checks/` — substitution token syntax (`check-substitution`, which lints the environment directories as well as the artifact layers), the `valuesFrom` three-layer chain (`check-valuesfrom`), the `P_*` interface (`check-interface`), secret placement, node-role placement (`check-placement`), values-file bindings (`check-values-files` — a values or patches file must bind to a release or Kustomization that exists), hardcoded-literal hygiene (`check-literals` — a value `config.yaml` parameterizes must appear in an overlay as its `${TOKEN}`, never verbatim), role-aware token resolution (`check-token-resolution`), substitution-engine parity (`check-engine-parity`), tool versions, and the Talos fragments. No `ENV=` needed.
- **`make check-pristine ENV=<env>`** is the apply-time gate: a clean working tree, an exact release-tag checkout, and — when the environment pins `dtk_version` — that the clone's tag matches it.
- **`tools/render.sh <env>`** renders everything offline, with no cluster: the merged values chain for every HelmRelease (release default → template → environment, with Helm's merge semantics), a kustomize build of every gitops layer, and a validation of the Talos machine-config fragments. Output lands under `../artifacts/<env>/render/` — the place to confirm what an edit actually produces before applying it.

Two properties of the schema checker are worth knowing:

- **The validator refuses to ignore a constraint.** `tools/validate.py` implements a subset of JSON Schema, and any keyword outside that subset is reported as a schema error rather than skipped. A constraint added to a schema therefore either takes effect or fails loudly — it can never be silently ignored.
- **The schemas have their own self-check.** `tools/test-validation.sh` runs accept and reject cases against the tracked samples and is the place to add a case when a rule changes.

### Rules that fail at plan time

Cross-field rules the schema cannot express are Terraform preconditions on the config-loader module. They fail the **plan**, before anything is created, each with a message naming the offending value:

| Condition | What it means |
|-----------|---------------|
| `version` is not `1` | `config.yaml` must declare the schema version it is written against |
| `dtk_version` is set and the clone is not checked out at that exact git tag | Environments and the clone version independently; the assert is what keeps "matched versions only" true — a mismatch fails, it does not warn |
| `cluster.role` is not `tooling`, `hub`, or `bare` | The role selects both the template directory and the Kustomization set |
| `cluster.name` resolves to an empty string | Set it, or let it default by naming the environment directory |
| `cert.email` is unset | The ACME account contact the CA sends expiry notices to; not defaulted |
| `cert.server` is unset | The certificate authority is always stated, never inherited |
| Self-managed infrastructure without `cluster.lb_ipam.pools` | On-prem clusters have no cloud load balancer; the pools are the address supply |
| `gw-extapi` / `gw-intapi` pools missing on a Hub, or present on another role | The FSPIOP gateways exist only on `role: hub` — four pools there, two elsewhere |
| Duplicate `lan` addresses, or a `lan` equal to `cluster.vip` | Every pool address and the API VIP must be distinct |
| Duplicate `wan` addresses across pools | Each published outside address maps to one gateway |
| Any `data.<store>.mode` is `external-managed` | Schema-reserved, not implemented — use `in-cluster-managed` or `external-unmanaged` |
| An `external-unmanaged` store has no `host` | The endpoint cannot be derived for a store the toolkit does not deploy |
| On `role: hub`, `app.api_type` is not `fspiop` or `iso20022` | The message dialect must be one the platform ships |
| On `role: hub`, a non-Talos provider with any `in-cluster-managed` store | The in-cluster data layer is packaged for Talos providers only; on AWS or DigitalOcean every store must be `external-unmanaged`, or the cluster advertises hostnames that were never deployed |
| The template references a placement group absent from the environment's `placement.yaml` | Unmapped groups reach the provider as literal node names and fail partway through apply, with VMs already created |
| The template has duplicate `node_groups[].name` | Group names become VM name suffixes and `for_each` keys |
| `registry.enabled: true` without `registry.url` | An enabled capability must carry its parameters |
| `object_storage.enabled: true` without all of `endpoint`, `bucket`, `region` | As above — none of the three is defaulted |
| `observability.enabled: true` without all of `loki_url`, `mimir_url`, `tempo_url` | As above |
| `object_storage.buckets`, `registry.robots`, or `observability.ingest_users` outside `role: tooling` | Serving buckets, robot accounts, and ingest accounts is what a Tooling Cluster does; a Hub consumes them |
| A declared bucket re-states a system bucket, breaks S3 naming rules, or repeats | The system buckets (`harbor`, `backups`, `thanos`, `loki`, `tempo`) always exist; names must be valid and unique |
| A declared robot name breaks the naming pattern or repeats | Robot names become Harbor accounts (`robot-<name>`) and secret names |
| One of `ACME_EAB_KEY_ID` / `ACME_EAB_HMAC_ENCODED` without the other | EAB is both-or-neither; this one fails at `make plan-config`, in the config stack |

The endpoint checks exist because an empty value would otherwise reach the cluster intact and fail at runtime instead. Since nothing is derived, these are the checks that catch a half-written section — see [ADR-017](../../architecture/decisions/017-explicit-capability-endpoints.md).

Next: [Deployment](deployment.md).
