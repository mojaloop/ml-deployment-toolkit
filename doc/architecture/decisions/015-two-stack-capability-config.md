# 015 — Two Terraform stacks and a capability-bound config model

[doc](../../index.md) / [architecture](../index.md) / [decisions](./) / 015 — Two stacks and capability config

**Date:** 2026-07-28
**Status:** accepted
**Audiences:** architect, platform developer, adopter (deploy)

Supersedes the profile mechanism of [ADR-012](012-tps-sizing-profiles.md); the TPS-tier naming it established is kept.

## Context

The configuration surface had grown to roughly seventy unvalidated parameters and forty secrets across two files per environment, and four separate problems had converged on it.

**Every config change was an infrastructure change.** One Terraform root owned both the VMs and the Flux inputs. Editing an alert recipient produced a plan that could, in principle, replace a node — so adopters read every plan carefully for changes that touched nothing physical, and a config-only fix cost a full apply.

**Sizing profiles duplicated per provider.** `config/providers/<p>/profiles/<role>/<tier>.yaml` meant N tiers × M providers. With six profiles in existence the copies had already drifted — `tps-10.yaml` carried a header saying "tps-1" — and only the machine-type portion was genuinely provider-specific.

**Endpoints were transcribed, not derived.** A Hub backed by a Tooling Cluster required hand-copying five URLs whose scheme the toolkit itself owns (`harbor.int.<d>`, `s3.int.<d>`, and three telemetry push paths). Every one was a typo waiting to fail late in reconciliation.

**Most secrets were not secrets from anywhere.** Around twenty of the forty `.env` entries were internal service passwords — MySQL accounts, Ory databases, Grafana admin — invented by the adopter, typed once, and thereafter meaningful only inside the cluster. Alongside them sat variables nothing read at all (`KEYCLOAK_*`, `HUBOP_OIDC_SECRET`, `PROXMOX_VE_INSECURE`, `ONBOARDING_COLLECTION_VERSION`, `OBSERVABILITY_MINIO_*`).

The design work is recorded in `_/configuration/` — the adopter journey and decisions D1–D9.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Keep one stack, add `-target` guidance | No migration; no state surgery | `-target` is documented by HashiCorp as a break-glass tool; nothing *prevents* an infra change, so the blast radius stays psychological rather than actual |
| Move `cluster-config` generation out of Terraform into a per-environment Flux artifact | Config converges with no `make` at all | Every adopter must build and publish an artifact; breaks the invariant that the distribution artifact is public, shared, and carries no adopter data |
| **Two Terraform roots, separate state** (chosen) | Config applies in seconds and *cannot* touch VMs; Terraform stays the single writer; no adopter artifacts | One-time `terraform state mv` per environment; two states to keep |
| Enumerated providers (infra/dns/cert only), sizing left per provider | Smallest change | Leaves data, object storage, registry, SMTP, and alerting as undocumented dimensions the code already had |
| **Flat capability sections + generic templates + per-provider mappings** (chosen) | Every dimension is visible and validated; tiers authored once | A second file to read when adding a provider; capability vocabulary to learn |

## Decision

**Two stacks.** `src/infra` provisions the cluster and installs Flux. `src/config` creates everything Flux consumes — `OCIRepository`, the Kustomization graph, `cluster-config`, `cluster-secrets`, and the values-override ConfigMaps. Separate state files under `artifacts/<env>/terraform/{infra,config}.tfstate`, and a new target:

```bash
make apply-config ENV=<env>
```

It plans and applies the config stack alone. Flux re-reads `postBuild.substituteFrom` on every reconcile, so the change converges without further action.

**Capability sections.** `config.yaml` is a flat list of top-level sections, one per capability, each naming its provider: `infra`, `dns`, `cert`, `artifact`, `registry`, `object_storage`, `observability`, `data`, `email`, `alerting`, `app`. Only `infra` and `dns` are required. "Capability" stays internal vocabulary — the adopter sees sections, not jargon. `profile:` is renamed `template:`; per-environment config moves from `config/environments/` to `environments/`.

**Two-layer templates.** A generic capacity template per tier (`config/templates/<role>/<tier>.yaml`) declares node groups — `{name, class, count, cores, memory, disks[], placement[]}` — plus the `app`/`data`/`tooling` tuning sections. A thin per-provider mapping (`config/templates/mappings/<provider>.yaml`) translates workload classes into instance types or VM defaults. `placement` is index-aligned, so per-node placement stays deterministic.

**The tooling preset.** `tooling.domain` plus `provider: tooling` on `registry`, `object_storage`, or `observability` derives all five endpoints from the one domain value.

**Per-store data modes.** `in-cluster-managed` (default), `external-unmanaged` (adopter-supplied endpoint; that store's `hub-data` Kustomization is not created), and `external-managed`, reserved in the schema and rejected with an explicit message until it exists.

**Generated internal secrets.** The `random_password` pattern already used for Kratos and Hydra extends to every internal service password, generated in the config stack. A matching UPPER_CASE name in `.env` overrides generation. `make secrets ENV=<env>` prints them. `.env` keeps only external credentials.

**Schema validation.** One JSON Schema per config kind under `config/schemas/`, run by `make validate` before Terraform. Cross-field rules that JSON Schema cannot express are Terraform preconditions in the config module.

## Consequences

- **A config change cannot destroy infrastructure.** Not "should not" — the config stack has no provider that can address a VM. This is what makes `make apply-config` safe to run casually, including for Helm value overrides.
- **Two states per environment to back up**, not one. `artifacts/<env>/terraform/` now holds `infra.tfstate` and `config.tfstate`, and the generated passwords live in the second one. Backing up only the infra state silently loses every internal credential.
- **Existing environments need a one-time `terraform state mv`** (`tools/migrate-state.sh`) to split their state. No VM is recreated by the split, but a mis-run migration plans a full rebuild — read that plan.
- **No dual-schema compatibility layer.** Every existing `config.yaml` and `.env` was rewritten by hand to the new shape. An old config does not load; it fails schema validation with a list of unknown keys.
- **Adding a provider now touches two files, not a directory tree** — a mapping file plus the module. Adding a tier is one file for all providers instead of one per provider.
- **The adopter cannot see internal passwords without the toolkit.** They exist in state and in the cluster, and `make secrets` is the way to read them. This removes the "password in a text file" habit and adds a dependency on state custody.
- **Values overrides work for every chart**, because each HelmRelease carries an optional `valuesFrom` its own override ConfigMap. The config stack `templatefile()`s them on the way in, so `${domain}` and the template's tuning keys work inside an override — at the cost that an unknown `${name}` now fails the apply instead of passing through, and a literal `${` needs escaping.
- **`external-managed` data is visible but unavailable.** The mode is in the schema so the shape is settled, and rejected at plan time so nobody discovers it half-works.
