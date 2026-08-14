# Prerequisites

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Prerequisites

**Audiences:** adopter (deploy)

Everything the adopter needs in place before the first `make plan-apply`. For what gets deployed and why, see [System overview](../../architecture/system-overview.md).

- [Tools](#tools)
- [Proxmox](#proxmox)
- [DNS](#dns)
- [OCI registry](#oci-registry)
- [Credentials checklist](#credentials-checklist)

## Tools

The toolchain is declared in `tools-versions.yaml` at the clone root, and enforced by a gate:

```bash
make check
```

That runs `tools/checks/check-tools.sh` (with the other repo contract checks) against the manifest — a missing or too-old required tool **fails**, it never warns, and the same check is a hard pre-apply gate. Run it before the first deploy rather than discovering a version problem mid-apply. The versions below mirror the manifest; the manifest is authoritative, and each floor's reason is recorded in it.

| Tool | Minimum | Used for |
|------|---------|----------|
| terraform | 1.9.0 | The IaC engine — Make wraps it. **`terraform`, not `tofu`**: the committed `.terraform.lock.hcl` files are registry-specific, so mixing OpenTofu against the same stack invalidates the locks |
| flux | 2.7.0 | Inspecting and forcing reconciliation. **The floor is load-bearing**: strict post-build substitution — fail on an undefined `${VAR}` — ships default-on with Flux 2.7; below it, an undefined token silently renders as an empty string in-cluster |
| helm | 3.14.0 | Offline rendering of values chains and the Cilium bootstrap manifest |
| talosctl | 1.8.0 | Machine config generation and node access (self-managed clusters) |
| kubectl | 1.29.0 | Cluster verification and troubleshooting commands |
| yq (mikefarah) | 4.40.0 | Reads `config.yaml` in `make validate` and `make push-gitops` |
| jq | 1.7 | Builds the secrets map for every target that loads `.env` |
| python3 | 3.9.0 | Runs the JSON Schema check in `make validate` |
| make | any | Runs the workflow; pre-installed on macOS and Linux |

`jsonnet` and `jb` are optional — only re-rendering the Thanos manifests (`make render-thanos`) needs them, and the gate merely warns when they are absent.

**Terraform is the engine, and the providers come pre-locked.** Both stacks commit their `.terraform.lock.hcl`, locked for macOS and Linux on amd64 and arm64 — the adopter never re-locks providers. That is also why the engine choice is fixed: lock entries name their registry, so running `tofu` against a stack the locks were written for breaks them.

**`yq` must be [mikefarah/yq](https://github.com/mikefarah/yq).** Two different programs are called `yq`, and `apt install yq`, `dnf install yq` and `pip install yq` all give the other one — a Python wrapper around `jq` that reports its version as `3.x` and does not understand the `-o=json` and `eval-all` syntax this toolkit uses. The gate detects and rejects it explicitly; to verify by hand:

```bash
yq --version                      # must print the mikefarah URL and v4.x
printf 'a: 1\n' | yq -o=json '.'  # must print {"a": 1}
```

Install it with `brew install yq` (macOS) or `snap install yq` (Linux). Without snap, take the static binary — remove the apt package first, or two `yq`s coexist and PATH order decides which one runs:

```bash
sudo apt-get remove -y yq
VER=v4.53.3; ARCH=$(dpkg --print-architecture)
sudo curl -fsSL -o /usr/local/bin/yq \
  "https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_${ARCH}"
sudo chmod 0755 /usr/local/bin/yq
```

## Proxmox

Proxmox with Talos Linux is the supported infrastructure. The adopter needs:

- **API access** — an API token (preferred) or user/password
- **SSH access** to the Proxmox nodes
- **A VM storage pool** for disks and images
- **The `Snippets` content type enabled** on the pool used for cloud-init — this is off by default and provisioning fails without it

Full walkthrough: [Provider setup](provider-setup.md).

## DNS

The DNS provider is independent of the infrastructure — any of the three works with Proxmox.

| Provider | Credential | Env variable |
|----------|-----------|--------------|
| Route53 | Access key with Route53 permissions | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |
| Cloudflare | Token scoped to `Zone:DNS:Edit` | `CLOUDFLARE_API_TOKEN` |
| DigitalOcean | Token with DNS write scope | `DIGITALOCEAN_TOKEN` |

The adopter needs a delegated DNS zone the toolkit can manage — `external-dns` creates and updates records in it automatically. See [Provider setup](provider-setup.md#dns-zone).

## OCI registry

Flux reconciles from an OCI artifact. The required credentials depend on where it lives.

**Pulling a public artifact** — no credentials. Public GitHub Container Registry artifacts pull anonymously.

**Private registry, or publishing a custom artifact** — set `OCI_REPO_USERNAME` and `OCI_REPO_PASSWORD`. For GitHub Container Registry, the password is a Personal Access Token:

```bash
gh auth refresh -s read:packages,write:packages
gh auth token
```

Use the GitHub username and the token output.

**Harbor pull-through cache** — only when a Hub pulls through a Tooling Cluster's Harbor (`registry.enabled: true`). Set `OCI_PROXY_USERNAME` and `OCI_PROXY_PASSWORD`.

## Credentials checklist

`.env` holds **external credentials only** — things that exist outside the deployment and cannot be invented. Every internal service password (databases, MinIO, Harbor, Grafana, the Ory stack, the hub admin) is generated by Terraform and read back with `make secrets ENV=<env>`. Nothing below needs choosing a password.

The full reference is [Configuration → Secrets](configuration.md#secrets); check these before starting, because a missing one fails late and quietly rather than at plan time.

**Every cluster:**

- Proxmox — `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_SSH_USERNAME`, `PROXMOX_VE_SSH_PASSWORD`
- DNS — the variable for the chosen provider, above
- OCI — `OCI_REPO_USERNAME`, `OCI_REPO_PASSWORD` if not pulling anonymously
- SMTP — `SMTP_USER`, `SMTP_PASSWORD` when `email:` is configured. The host, port, and sender address are `config.yaml`, not secrets
- Telegram — `TELEGRAM_BOT_TOKEN` when `alerting.telegram` is configured

**Tooling Cluster (`tooling`):**

- Nothing further is required. `MINIO_ROOT_USER` may be set to override the default `minioadmin`; the MinIO, Harbor, and Grafana passwords are generated.
- **Alerting delivery is still the thing to get right.** The destinations live in `config.yaml` under `alerting:` and the credentials in `.env`. **Without them, 22 alert rules evaluate but nothing is delivered** — the most common way a deployment ends up believing it has no alerting. See [Observability](../../architecture/observability.md#alerting).

**Hub (`hub`):**

- `OCI_PROXY_USERNAME` / `OCI_PROXY_PASSWORD` and `BACKUP_S3_ACCESS_KEY` / `BACKUP_S3_SECRET_KEY` when the Hub uses a Tooling Cluster's Harbor and object storage — both come from `make secrets` on that Tooling Cluster ([hand-off](tooling-cluster.md#hand-off-to-the-hub))
- Credentials for any `external-unmanaged` data store, under the generated name they replace (`MYSQL_ROOT_PASSWORD`, `MONGODB_ROOT_PASSWORD`, …)
- Every other database, Ory, and identity password is generated — including the HubOps login, whose address is `app.hub.admin_email` in `config.yaml`

Next: [Provider setup](provider-setup.md).
