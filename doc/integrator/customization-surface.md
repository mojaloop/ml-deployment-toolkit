# Customization Surface

[doc](../index.md) / [integrator](index.md) / Customization surface

**Audiences:** system integrator

Where the integrator can customize, and what each layer costs at upgrade time. The rule throughout: **customize at the highest layer that meets the need**, because the lower the layer, the more the integrator carries forward forever.

- [The layers](#the-layers)
- [Configuration — no fork](#configuration-no-fork)
- [Helm value overrides — no fork](#helm-value-overrides-no-fork)
- [Manifest patches — no fork](#manifest-patches-no-fork)
- [Forking — carried forever](#forking-carried-forever)
- [Deciding](#deciding)

## The layers

The surface has exactly two sides. On one side is the **environment layer** — everything in the adopter-owned `../environments/<env>/` repository, which lives beside the clone and never touches it. On the other is **forking** — any edit to the clone itself, `providers/<provider>/params.yaml` and the template files included, which is forking public software and is visible by design: `make check-pristine` verifies the clone is clean and at an exact release tag, and reports any divergence.

From cheapest to most expensive to maintain:

| Layer | Fork? | Carried at upgrade? | Reach for it when |
|-------|:---:|:---:|-------------|
| Configuration (`config.yaml`, `.env`) | No | No | Anything an adopter could set |
| Helm value overrides (`values/<namespace>/<release>.yaml`) | No | No | Tuning any shipped chart's values |
| Manifest patches (`patches/<kustomization>.yaml`) | No | No | Tuning what is not a chart — the data layer above all |
| Placement and infrastructure sidecars (`placement.yaml`, `proxmox/proxmox.yaml`) | No | No | Mapping placement groups to physical nodes; network bridge and storage pools |
| Fork (clone edits, `params.yaml`, templates) | Yes | **Every upgrade** | The environment layer genuinely cannot express it |

The no-fork rows are not integrator-specific — they are the [adopter](../adopter/deploy/configuration.md) mechanisms, and together they are the environment layer. That is the point: most customization is configuration a client could have done themselves, and it costs the integrator nothing at upgrade time because it lives in the client's environment repository, not in a fork.

## Configuration: no fork

Everything in `config.yaml` and `.env` is per-environment and carried by no one. Infrastructure and DNS providers, deployment template, domain, artifact source, registry and object-storage bindings, data modes, email and alerting — all configuration. The environment directory also carries `placement.yaml` (placement groups → physical nodes), `proxmox/proxmox.yaml` (network bridge and storage pools), and `talos.yaml` (node OS facts), so physical-infrastructure tailoring needs no fork either. If a client's need is expressible here, it is free.

See [Configuration](../adopter/deploy/configuration.md) for the full schema.

## Helm value overrides: no fork

The integrator can override the platform's Helm values for **any** chart the distribution ships, without forking, by placing a file at `values/<namespace>/<release>.yaml` in the environment directory — the path *is* the binding; there is no `target:` header. Every HelmRelease ends its `valuesFrom` chain with the optional three-layer tail — the selected template's `<namespace>-<release>-values-template` ConfigMap, then the override twins, a ConfigMap and a Secret both named `<namespace>-<release>-values-override` — so the file is picked up with no wiring change. Applying one is `make apply-config ENV=<env>`: seconds, and it cannot touch infrastructure.

This covers a large amount of application-level tailoring — resource sizing, feature flags, chart-exposed settings — with zero maintenance burden, because the override lives in the client's environment repository. It reaches every value the distribution sets, not just the ones it leaves blank: no HelmRelease uses inline `spec.values`, the distribution's own values arrive as a `<release>-values` ConfigMap listed first in `valuesFrom`, and the client's override twins are listed last, so they win.

The files are templated: `${DOMAIN}`, `${CLUSTER_NAME}`, the resolved telemetry URLs, and the other config-derived tokens expand at apply time, so a client's override does not re-hardcode values the cluster already knows. An undefined `${NAME}` fails the apply rather than passing through. Lines referencing a `.env` key land in the Secret twin, never the ConfigMap — a client can override a credentialed value without it appearing in a ConfigMap. See [Configuration → Helm value overrides](../adopter/deploy/configuration.md#helm-value-overrides).

## Manifest patches: no fork

Value overrides stop where charts stop. The data layer is the case that matters: Kafka, MySQL, MongoDB, and Redis ship as custom resources for their operators, not as charts, so no values file reaches them. Their tuning — storage sizes, partition counts, MySQL settings — is literal in the shipped manifests, scaled per tier by the selected template's own patches, so from the environment there is no values-style surface at all.

For everything past that, the integrator drops a file named for the Flux Kustomization in the environment's `patches/` directory, and its contents are appended to that Kustomization's `spec.patches`. JVM heap, replica counts, resource requests, an operator setting the distribution never anticipated — all reachable, without touching `gitops/`. The mechanism is not data-layer-specific: any Kustomization can be named, so it covers every plain manifest the distribution ships.

Two differences from value overrides shape when to use it. Patches are **kustomize**, so the client writes target-matching semantics rather than a YAML map, and lists replace rather than merge. And a patch whose target matches nothing fails the whole Kustomization rather than one release — on a data store, that blocks `hub-app` behind it. It is the more powerful and the sharper tool; prefer a value override wherever one exists.

See [Configuration → Manifest patches](../adopter/deploy/configuration.md#manifest-patches).

## Forking: carried forever

When the environment layer genuinely cannot express the need — a new provider, a changed module, a service the distribution does not include, a different provider interface value — the integrator forks and changes the code. The mechanics are the [Platform guide](../platform/index.md): the same module pipeline, the same "add a provider / add a service" procedures.

The boundary sits closer than it may look: `providers/<provider>/params.yaml` and the role/capacity template files are part of the clone, so editing them is a fork, not configuration. And a fork is a **visible** act — the clone is meant to sit pristine at an exact release tag, `make check-pristine` verifies exactly that, and any local edit makes the divergence report. That visibility is by design: a derivative is forked public software, maintained and published openly as such, never a quietly patched clone.

What is different for an integrator is the **cost model**. Every line the integrator changes in `src/`, `gitops/`, or `providers/` is a line the integrator reconciles against upstream at every update. A fork is not a one-time cost; it is a recurring one, paid at each rebase. This is why the discipline is to fork as narrowly as possible — change the least that meets the need, and prefer a clean addition (a new file, a new module) over an edit to an existing one, because additions rebase more cleanly than edits.

## Deciding

For any client requirement, walk down the layers and stop at the first that works:

1. **Can `config.yaml` / `.env` / `placement.yaml` / `proxmox/proxmox.yaml` / `talos.yaml` express it?** → configuration. Done, free.
2. **Is it a value on a chart the distribution ships?** → value override. Done, free.
3. **Is it a field on a manifest the distribution ships?** → manifest patch. Done, free.
4. **Could it be any of those, if the field existed?** → consider [contributing it upstream](../platform/index.md) so it becomes free — for the integrator and everyone.
5. **Only then, fork** — and change the minimum.

The trap is reaching for a fork when a value override or a patch would do, because the fork is invisible today and expensive at every future upgrade. When in doubt, spend the effort finding a no-fork path before spending it on a fork.
