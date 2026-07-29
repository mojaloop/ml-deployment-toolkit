# Adding a Provider

[doc](../index.md) / [platform](index.md) / Adding a provider

**Audiences:** platform developer

Adding an infrastructure provider. The contract is narrow — produce a cluster and a kubeconfig — which is what keeps the rest of the toolkit provider-agnostic.

- [The contract](#the-contract)
- [1. Write the module](#1-write-the-module)
- [2. Wire it into the infra stack](#2-wire-it-into-the-infra-stack)
- [3. Add the provider mapping](#3-add-the-provider-mapping)
- [4. Vendor layer, if needed](#4-vendor-layer-if-needed)
- [What not to touch](#what-not-to-touch)

## The contract

A provider module does exactly one thing: **provision a cluster and return a kubeconfig.** Everything above that is identical across providers, so if adding a provider means editing DNS, TLS, or application code, something is in the wrong place.

Use the existing modules as references — `proxmox` for a self-managed cluster (the more involved case, composing VM, Talos-config, and bootstrap sub-modules) and `digitalocean` for a managed one (a single module wrapping a managed Kubernetes service).

## 1. Write the module

Create `src/modules/<provider>/`. It must:

- Accept the merged configuration from config-loader
- Provision the cluster
- Write a kubeconfig to the environment's artifacts path
- Output `kubeconfig_path` and `cluster_endpoint`

A managed provider is usually one module. A self-managed one composes sub-modules the way `proxmox` does. Match the output names of the existing modules exactly — downstream wiring reads them by name.

## 2. Wire it into the infra stack

There are **four** edit points in `src/infra/main.tf`, and missing the fourth is the common mistake — it leaves `kubeconfig_path` null and the deploy fails in a confusing way. The config stack (`src/config`) needs no provider-specific edit at all; it reads `infra.provider` only to name the vendor Kustomization.

1. **The module block** — instantiate `module "<provider>"`, guarded so it only runs when selected.
2. **`local.provider_outputs`** — add the new module's outputs under the provider name.
3. **`local.kubeconfig_paths`** — add the new provider's kubeconfig path here.

   This is the one the old documentation omitted. The kubeconfig **must** be read from this map, not through `local.active_provider` — the `active_provider` object carries plan-time-unknown outputs, and routing the kubeconfig through it breaks planning. There is an in-code comment at this exact spot saying so; heed it.

4. **`flux_bootstrap` depends_on** — add the new module so Flux waits for the cluster to exist.

After all four, `local.kubeconfig_paths[<provider>]` resolves and `flux_bootstrap` receives a real path.

## 3. Add the provider mapping

Create one file: `config/templates/mappings/<provider>.yaml`, validated against `config/schemas/mapping.schema.json`.

It translates the provider-independent capacity templates into concrete machines, and holds nothing else:

- `instance_types` — workload class → instance type or size, for managed services
- `vm_defaults`, `storage`, `talos` — VM shape, datastores, and image platform, for self-managed providers
- `talos-patches` — provider-specific machine-config patches, if any

**No new tier files.** The capacity templates under `config/templates/{cc,env,base}/` are provider-independent and already cover the new provider — a class the mapping does not list falls back to a built-in default, so the mapping should name every class the templates use. `make validate` schema-checks the mapping alongside the environment config.

## 4. Vendor layer, if needed

A self-managed cluster needs cluster-level resources a managed service would provide — CNI, Gateway API CRDs, LB-IPAM, storage. Those live in a vendor Kustomization.

`gitops/talos/` is the existing example. If the new provider is self-managed and needs the same class of resources, add a vendor directory and ensure `flux-config` names it for that provider. A managed provider that ships its own CNI and storage needs no vendor layer — and `has_vendor` in `flux-config` must reflect that, or Flux will look for a directory that does not exist. (An existing mismatch of exactly this kind is tracked in `discrepancies.md` item 3 — do not replicate it.)

## What not to touch

If adding a provider means editing any of these, reconsider the design:

- `gitops/platform/`, `gitops/env*/`, `gitops/cc*/` — the shared layers are provider-agnostic by invariant
- DNS, cert-manager, or observability configuration
- Application manifests

A new provider is a new module, its mapping file, and possibly a vendor Kustomization. Nothing else. If a shared manifest would need to change, the provider-specific part of it belongs in a substituted variable or the vendor layer instead.
