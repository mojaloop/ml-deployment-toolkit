# Adding a Provider

[doc](../index.md) / [platform](index.md) / Adding a provider

**Audiences:** platform developer

Adding an infrastructure provider. The contract is narrow — produce a cluster and a kubeconfig ([ADR-024](../architecture/decisions/024-narrow-provider-boundary.md)) — which is what keeps the rest of the toolkit provider-agnostic. The registration wiring around that contract is wider than the contract itself; this page lists all of it.

- [The contract](#the-contract)
- [1. Write the module](#1-write-the-module)
- [2. Register the provider](#2-register-the-provider)
- [3. Wire it into the infra stack](#3-wire-it-into-the-infra-stack)
- [4. Add the provider mapping](#4-add-the-provider-mapping)
- [5. Vendor layer, if needed](#5-vendor-layer-if-needed)
- [What not to touch](#what-not-to-touch)

## The contract

A provider module does exactly one thing: **provision a cluster and return a kubeconfig.** Everything above that is identical across providers, so if adding a provider means editing DNS, TLS, or application code, something is in the wrong place.

Use the existing modules as references — `proxmox` for a self-managed cluster (the more involved case, composing VM, Talos-config, and bootstrap sub-modules) and `digitalocean` for a managed one (a single module wrapping a managed Kubernetes service). One caution on the references: the Proxmox/Talos path is the one exercised end to end; the managed modules provision clusters but their role layers are not deployable end to end today ([Provider model](../architecture/provider-model.md#infrastructure-providers)), so copy their *shape*, not their untested details.

## 1. Write the module

Create `src/modules/<provider>/`. It must:

- Accept the merged configuration from config-loader
- Provision the cluster
- Write a kubeconfig to **exactly** `${var.artifacts_path}/kubernetes/kubeconfig` — the config stack's providers read that literal path (`src/config/providers.tf`), so any other filename breaks the config stack silently
- Output `kubeconfig_path` and `cluster_endpoint`

A managed provider is usually one module. A self-managed one composes sub-modules the way `proxmox` does. Match the output names of the existing modules exactly — downstream wiring reads them by name.

## 2. Register the provider

The provider name must be known everywhere the toolkit enumerates providers. Missing any of these fails at a different stage, so treat the list as a checklist:

| Edit | Where | Fails without it |
|------|-------|------------------|
| `infra.provider` enum | `config/schemas/environment.schema.json` | `make validate` rejects the name — the schema is closed |
| `infra.<provider>` block | same schema | No place for provider-specific keys; the root is `additionalProperties: false` |
| `required_providers` entry | `src/infra/versions.tf` | `terraform init` cannot resolve the provider plugin |
| `provider "<name>" {}` block | `src/infra/providers.tf` | The module has no configured provider to run under |
| Node-shape output | `src/modules/config-loader/` (the pattern of `aws_node_groups` / `do_node_pools`) | The module has no expanded machine shapes to consume |
| Provider classification | `is_talos_provider` in `config-loader`, `is_talos` / `has_vendor` in `flux-config` | The data layer, vendor Kustomization, and Talos-only behaviour key off these hardcoded lists |

That last row is also where the config stack *is* provider-aware — `flux-config` is part of the config stack, and its provider lists must match reality or Flux references a vendor directory that does not exist.

## 3. Wire it into the infra stack

There are **four** edit points in `src/infra/main.tf`, and missing the fourth is the common mistake — it leaves `kubeconfig_path` null and the deploy fails in a confusing way.

1. **The module block** — instantiate `module "<provider>"`, guarded so it only runs when selected.
2. **`local.provider_outputs`** — add the new module's outputs under the provider name.
3. **`local.kubeconfig_paths`** — add the new provider's kubeconfig path here.

   The kubeconfig **must** be read from this map, not through `local.active_provider` — the `active_provider` object carries plan-time-unknown outputs, and routing the kubeconfig through it breaks planning. There is an in-code comment at this exact spot saying so; heed it.

4. **`flux_bootstrap` depends_on** — add the new module so Flux waits for the cluster to exist.

After all four, `local.kubeconfig_paths[<provider>]` resolves and `flux_bootstrap` receives a real path.

## 4. Add the provider mapping

Create one file: `config/templates/mappings/<provider>.yaml`, validated against `config/schemas/mapping.schema.json`.

It translates the provider-independent capacity templates into concrete machines, and holds nothing else:

- `instance_types` — workload class → instance type or size, for managed services
- `vm_defaults`, `storage`, `talos` — VM shape, datastores, and image platform, for self-managed providers
- `vpc` and similar provider constants, where the managed service needs them
- `talos-patches` — provider-specific machine-config patches, if any

**No new tier files.** The capacity templates under `config/templates/{tooling,hub,bare}/` are provider-independent and already cover the new provider — a class the mapping does not list falls back to a built-in default, so the mapping should name every class the templates use. `make validate` schema-checks the mapping alongside the environment config; note the mapping schema is permissive, so the check is shape-level, not exhaustive.

## 5. Vendor layer, if needed

A self-managed cluster needs cluster-level resources a managed service would provide — CNI, Gateway API CRDs, LB-IPAM, storage. Those live in a vendor Kustomization.

`gitops/talos/` is the existing example. If the new provider is self-managed and needs the same class of resources, add a vendor directory and ensure `has_vendor` in `flux-config` names the provider. A managed provider that ships its own CNI and storage needs no vendor layer — and `has_vendor` must say so, or Flux will look for a directory that does not exist. The current `flux-config` lists `aws` and `gcp` in `has_vendor` with no matching `gitops/` directory — a standing mismatch of exactly this kind; do not replicate it.

## What not to touch

If adding a provider means editing any of these, reconsider the design:

- `gitops/platform/`, `gitops/hub*/`, `gitops/tooling*/` — the shared layers are provider-agnostic by invariant
- DNS, cert-manager, or observability configuration
- Application manifests

A new provider is a new module, its registration entries, its mapping file, and possibly a vendor Kustomization. Nothing else. If a shared manifest would need to change, the provider-specific part of it belongs in a substituted variable or the vendor layer instead.
