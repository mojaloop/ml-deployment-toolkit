# ml-deployment-toolkit

An infrastructure-agnostic distribution of [Mojaloop](https://mojaloop.io/) — the open-source real-time payment switch. The toolkit packages Terraform modules and FluxCD GitOps manifests into OCI artifacts, so a full Mojaloop deployment becomes a single `make plan-apply`. Proxmox with Talos Linux is the supported infrastructure today; the provider model is built for more ([provider model](doc/architecture/provider-model.md)).

## What it deploys

Two cluster kinds, each driven from its own environment config under `environments/<env>/`.

### Tooling Cluster (`role: tooling`)

An optional cluster hosting the supporting services a Hub points at: Harbor (OCI registry and pull-through cache), Vault (secrets and PKI), MinIO (object storage for backups), FluxCD, and the observability backend. It is a reference implementation — each endpoint a Hub consumes may equally point at a cloud service or existing infrastructure. A single Hub can pull artifacts from a public OCI registry and run standalone; the Tooling Cluster earns its place in multi-environment and air-gapped operation.

→ [Deploy a Tooling Cluster](doc/adopter/deploy/tooling-cluster.md)

### Hub / Switch (`role: hub`)

A cluster running Mojaloop itself: central ledger, account lookup, quoting, settlements, MCM, the Ory auth stack, and the data layer (MySQL, Kafka, MongoDB, Redis — in-cluster or external). Participants connect to it over mTLS via the FSPIOP endpoint.

→ [Deploy a Hub](doc/adopter/deploy/hub.md)

## Quick start

A first deployment needs a provider account, a delegated DNS zone, and a few CLI tools — see [prerequisites](doc/adopter/deploy/prerequisites.md) and [provider setup](doc/adopter/deploy/provider-setup.md).

```bash
# 1. Create the environment from a sample
#    mlf-lab1-cc1 is the Tooling Cluster sample; mlf-lab1-sw1 the Hub sample
mkdir -p environments/<env>
cp environments/mlf-lab1-cc1/config.yaml.sample environments/<env>/config.yaml
cp environments/mlf-lab1-cc1/.env.sample       environments/<env>/.env

# 2. Choose capabilities, template, and parameters
$EDITOR environments/<env>/config.yaml

# 3. Supply external credentials only — internal service passwords are generated
$EDITOR environments/<env>/.env

# 4. Check it before spending time on a deploy
make validate ENV=<env>

# 5. Deploy
make plan-apply ENV=<env>
```

Afterwards:

```bash
make secrets ENV=<env>        # generated internal passwords (Harbor, MinIO, DBs, ...)
make apply-config ENV=<env>   # push config changes in seconds, without touching VMs
```

## How it is organised

| Path | Contents |
|---|---|
| `environments/<env>/` | The deployment: `config.yaml`, `.env`, optional `values/` overrides and `patches/`, and the perf topology + scenarios |
| `config/` | Templates (capacity + per-provider mappings), JSON Schemas, platform definitions, Talos patches, rendered bootstrap manifests |
| `src/infra/` | Terraform stack: cluster VMs / managed Kubernetes + Flux bootstrap |
| `src/config/` | Terraform stack: everything Flux consumes (config, secrets, Kustomizations) |
| `gitops/` | The distribution artifact — environment-neutral manifests |
| `rendering/` | Sources for the rendered manifests (Thanos Jsonnet, Cilium values) |
| `tools/` | Validation, schema self-check, state migration |
| `ttk/` | Testing Toolkit collections — hub provisioning |
| `doc/` | The documentation — routed by audience |
| `perf/` | Load generation and measurement — code only |
| `artifacts/<env>/` | Generated per environment: state, kubeconfig, Talos configs (git-ignored) |

Configuration and infrastructure are separate Terraform stacks with separate state, so a config change is a fast, low-risk `make apply-config` that cannot touch running VMs.

## Performance testing

Load generation against the participant SDK outbound APIs, measuring what a payer
actually experiences: discovery, quote and transfer timed separately.

```bash
make perf-check ENV=<env>                  # preflight — endpoints and parties
make perf-seed  ENV=<env>                  # register + verify test parties
make perf-run   ENV=<env> SCENARIO=smoke   # 30s, proves the chain works
make perf-run   ENV=<env> SCENARIO=baseline-1tps
make perf-index                            # regenerate perf/INDEX.md
```

Copy `environments/mlf-lab1-sw1/perf-topology.yaml.sample` and the scenarios
beside it into the environment to get started. Results land in
`perf-result/<env>/<scenario>/<timestamp>/`, git-ignored — they stay local to
the machine that ran them. See [perf/README.md](perf/README.md).

## Documentation

Full guide — architecture, adopter, platform, integrator, participant — is in [doc/](doc/index.md).
