# ml-deployment-toolkit

An infrastructure-agnostic distribution of [Mojaloop](https://mojaloop.io/) — the open-source real-time payment switch. The toolkit packages Terraform modules and FluxCD GitOps manifests into OCI artifacts, so a full Mojaloop deployment becomes a single `make plan-apply`. Proxmox with Talos Linux is the supported infrastructure today; the provider model is built for more ([provider model](doc/architecture/provider-model.md)).

## What it deploys

Two cluster kinds, each driven from its own environment config under `../environments/<env>/` — a sibling of the clone, owned by the adopter as its own git repository.

### Tooling Cluster (`role: tooling`)

An optional cluster hosting the supporting services a Hub points at: Harbor (OCI registry and pull-through cache), Vault (secrets and PKI), MinIO (object storage for backups), FluxCD, and the observability backend. It is a reference implementation — each endpoint a Hub consumes may equally point at a cloud service or existing infrastructure. A single Hub can pull artifacts from a public OCI registry and run standalone; the Tooling Cluster earns its place in multi-environment and air-gapped operation.

→ [Deploy a Tooling Cluster](doc/adopter/deploy/tooling-cluster.md)

### Hub / Switch (`role: hub`)

A cluster running Mojaloop itself: central ledger, account lookup, quoting, settlements, MCM, the Ory auth stack, and the data layer (MySQL, Kafka, MongoDB, Redis — in-cluster or external). Participants connect to it over mTLS via the FSPIOP endpoint.

→ [Deploy a Hub](doc/adopter/deploy/hub.md)

## Quick start

A first deployment needs a provider account, a delegated DNS zone, and a few CLI tools — see [prerequisites](doc/adopter/deploy/prerequisites.md) and [provider setup](doc/adopter/deploy/provider-setup.md).

The clone stays pristine — environments and generated artifacts live *beside* it, never inside it. Upgrading the toolkit is a checkout of a newer tag, never a rebase.

```bash
# 1. Clone into a project root — environments/ and artifacts/ will be siblings
mkdir -p <project-root> && cd <project-root>
git clone https://github.com/mojaloop/ml-deployment-toolkit.git
cd ml-deployment-toolkit

# 2. Copy a reference environment out of the clone and strip the .sample suffixes
#    examples/environments/tooling is the Tooling Cluster sample; examples/environments/hub the Hub sample
cp -R examples/environments/hub ../environments/<env>
(cd ../environments/<env> && for f in $(find . -name '*.sample'); do mv "$f" "${f%.sample}"; done && git init)

# 3. Choose capabilities, template, and parameters; map placement groups to nodes;
#    supply external credentials only — internal service passwords are generated
$EDITOR ../environments/<env>/config.yaml
$EDITOR ../environments/<env>/placement.yaml
$EDITOR ../environments/<env>/.env        # never committed — the .gitignore ships with the sample

# 4. Check it before spending time on a deploy (run from the clone root)
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
| `../environments/<env>/` | Adopter-owned sibling of the clone, each environment its own git repo: `config.yaml`, `.env`, `placement.yaml`, `talos.yaml`, `proxmox/proxmox.yaml`, optional `state-backend.yaml`, `values/`, `patches/`, `talos/` and `proxmox/<pool>.yaml` overlays, and the perf topology + scenarios |
| `../artifacts/<env>/` | Generated output outside the clone: `state/` (Terraform state — the adopter's own backup), `plans/` (disposable), kubeconfig, Talos configs |
| `../rendered/<env>/` | Committable golden renders (`make render`) — the offline merge result, apart from secret-bearing artifacts |
| `providers/<provider>/` | Provider packages: `params.yaml` (contract), `classes.yaml` (per-class materializations), `templates/`, `patches/`, `gitops-delta/`, `terraform/` |
| `config/` | L1 platform material: JSON Schemas, platform definitions (versions, class identity, provider contract), rendered bootstrap manifests |
| `examples/environments/` | Reference environments (`hub/`, `tooling/`) as `.sample` files — copied out to start a deployment |
| `src/infra/` | Terraform stack: cluster VMs / managed Kubernetes + Flux bootstrap |
| `src/config/` | Terraform stack: everything Flux consumes (config, secrets, Kustomizations) |
| `src/render/` | Resource-free stack behind `make render` — exports the materialized merge, never applied |
| `src/engine/` | The engine modules: config-loader, flux-config, flux-bootstrap |
| `gitops/` | The distribution artifact — environment-neutral manifests |
| `rendering/` | Sources for the rendered manifests (Thanos Jsonnet, Cilium values) |
| `tools/` | Validation, repo contract checks, offline render + explain, `valuesFrom` chain generation, backend generation + state-backend migration, support bundles |
| `tools-versions.yaml` | Pinned CLI tool floors (Terraform, Flux, yq, …) — checked as a hard gate before every apply |
| `ttk/` | Testing Toolkit collections — hub provisioning |
| `doc/` | The documentation — routed by audience |
| `perf/` | Load generation and measurement — code only |

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

Copy `examples/environments/hub/perf-topology.yaml.sample` and the scenarios
beside it into the environment to get started. Results land in
`perf-result/<env>/<scenario>/<timestamp>/`, git-ignored — they stay local to
the machine that ran them. See [perf/README.md](perf/README.md).

## Documentation

Full guide — architecture, adopter, platform, integrator, participant — is in [doc/](doc/index.md).
