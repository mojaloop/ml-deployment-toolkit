# Adding a Provider

[doc](../index.md) / [platform](index.md) / Adding a provider

**Audiences:** platform developer

Adding an infrastructure provider. The contract is narrow — produce a cluster and a kubeconfig — which is what keeps the rest of the toolkit provider-agnostic.

- [The contract](#the-contract)
- [1. Write the module](#1-write-the-module)
- [2. Wire it into main.tf](#2-wire-it-into-maintf)
- [3. Add provider config and profiles](#3-add-provider-config-and-profiles)
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

## 2. Wire it into main.tf

There are **four** edit points in `src/main.tf`, and missing the fourth is the common mistake — it leaves `kubeconfig_path` null and the deploy fails in a confusing way.

1. **The module block** — instantiate `module "<provider>"`, guarded so it only runs when selected.
2. **`local.provider_outputs`** — add the new module's outputs under the provider name.
3. **`local.kubeconfig_paths`** — add the new provider's kubeconfig path here.

   This is the one the old documentation omitted. The kubeconfig **must** be read from this map, not through `local.active_provider` — the `active_provider` object carries plan-time-unknown outputs, and routing the kubeconfig through it breaks planning. There is an in-code comment at this exact spot saying so; heed it.

4. **`flux_bootstrap` depends_on** — add the new module so Flux waits for the cluster to exist.

After all four, `local.kubeconfig_paths[<provider>]` resolves and `flux_bootstrap` receives a real path.

## 3. Add provider config and profiles

Create `config/providers/<provider>/`:

- `config.yaml` — provider defaults
- `profiles/cc/` and `profiles/env/` — sizing profiles, matching the shape of the existing providers' profiles

The profile files are what `config.yaml`'s `profile:` field selects. Without at least one profile for each role the provider will support, an adopter cannot size a cluster on it.

## 4. Vendor layer, if needed

A self-managed cluster needs cluster-level resources a managed service would provide — CNI, Gateway API CRDs, LB-IPAM, storage. Those live in a vendor Kustomization.

`gitops/talos/` is the existing example. If the new provider is self-managed and needs the same class of resources, add a vendor directory and ensure `flux-config` names it for that provider. A managed provider that ships its own CNI and storage needs no vendor layer — and `has_vendor` in `flux-config` must reflect that, or Flux will look for a directory that does not exist. (An existing mismatch of exactly this kind is tracked in `discrepancies.md` item 3 — do not replicate it.)

## What not to touch

If adding a provider means editing any of these, reconsider the design:

- `gitops/platform/`, `gitops/env*/`, `gitops/cc*/` — the shared layers are provider-agnostic by invariant
- DNS, cert-manager, or observability configuration
- Application manifests

A new provider is a new module, its config and profiles, and possibly a vendor Kustomization. Nothing else. If a shared manifest would need to change, the provider-specific part of it belongs in a substituted variable or the vendor layer instead.
