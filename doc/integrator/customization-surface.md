# Customization Surface

[doc](../index.md) / [integrator](index.md) / Customization surface

**Audiences:** system integrator

Where the integrator can customize, and what each layer costs at upgrade time. The rule throughout: **customize at the highest layer that meets the need**, because the lower the layer, the more the integrator carries forward forever.

- [The layers](#the-layers)
- [Configuration — no fork](#configuration-no-fork)
- [Helm value overrides — no fork](#helm-value-overrides-no-fork)
- [Forking — carried forever](#forking-carried-forever)
- [Deciding](#deciding)

## The layers

From cheapest to most expensive to maintain:

| Layer | Fork? | Carried at upgrade? | Reach for it when |
|-------|:---:|:---:|-------------|
| Configuration | No | No | Anything an adopter could set |
| Helm value overrides | No | No | Tuning any shipped chart's values |
| Fork | Yes | **Every upgrade** | Config genuinely cannot express it |

The first two are not integrator-specific — they are the [adopter](../adopter/deploy/configuration.md) mechanisms. That is the point: most customization is configuration a client could have done themselves, and it costs the integrator nothing at upgrade time because it lives in the client's environment, not in the fork.

## Configuration: no fork

Everything in `config.yaml` and `.env` is per-environment and carried by no one. Infrastructure and DNS providers, deployment template, domain, artifact source, registry and object-storage bindings, data modes, email and alerting — all configuration. If a client's need is expressible here, it is free.

See [Configuration](../adopter/deploy/configuration.md) for the full schema.

## Helm value overrides: no fork

The integrator can override the platform's Helm values for **any** chart the distribution ships, without forking, by placing files in the environment's `values/` directory named for the HelmRelease. Every HelmRelease carries an optional `valuesFrom` its own `<name>-values-override` ConfigMap, so the file is picked up with no wiring change.

This covers a large amount of application-level tailoring — resource sizing, feature flags, chart-exposed settings — with zero maintenance burden, because the override lives in the client's environment. Applying one is `make apply-config ENV=<env>`: seconds, and it cannot touch infrastructure.

The files are templated: `${domain}`, `${cluster_name}`, the resolved telemetry URLs, and the template's tuning keys expand at apply time, so a client's override does not re-hardcode values the cluster already knows. Secrets are deliberately not exposed, and an unknown `${name}` fails the apply rather than passing through. See [Configuration → Helm value overrides](../adopter/deploy/configuration.md#helm-value-overrides).

## Forking: carried forever

When configuration and overrides genuinely cannot express the need — a new provider, a changed module, a service the distribution does not include — the integrator forks and changes the code. The mechanics are the [Platform guide](../platform/index.md): the same module pipeline, the same "add a provider / add a service" procedures.

What is different for an integrator is the **cost model**. Every line the integrator changes in `src/` or `gitops/` is a line the integrator reconciles against upstream at every update. A fork is not a one-time cost; it is a recurring one, paid at each rebase. This is why the discipline is to fork as narrowly as possible — change the least that meets the need, and prefer a clean addition (a new file, a new module) over an edit to an existing one, because additions rebase more cleanly than edits.

## Deciding

For any client requirement, walk down the layers and stop at the first that works:

1. **Can `config.yaml` / `.env` express it?** → configuration. Done, free.
2. **Is it a value on a chart the distribution ships?** → value override. Done, free.
3. **Could it be either, if the field existed?** → consider [contributing it upstream](../platform/index.md) so it becomes free — for the integrator and everyone.
4. **Only then, fork** — and change the minimum.

The trap is reaching for a fork when a value override would do, because the fork is invisible today and expensive at every future upgrade. When in doubt, spend the effort finding a no-fork path before spending it on a fork.
