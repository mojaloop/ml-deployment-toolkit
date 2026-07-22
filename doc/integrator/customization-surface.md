# Customization Surface

[doc](../index.md) / [integrator](index.md) / Customization surface

**Audiences:** system integrator

Where you can customize, and what each layer costs you at upgrade time. The rule throughout: **customize at the highest layer that meets the need**, because the lower you go, the more you carry forward forever.

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
| Helm value overrides | No | No | Tuning `mojaloop` or `mcm` chart values |
| Fork | Yes | **Every upgrade** | Config genuinely cannot express it |

The first two are not integrator-specific — they are the [adopter](../adopter/deploy/configuration.md) mechanisms. That is the point: most customization is configuration a client could have done themselves, and it costs you nothing at upgrade time because it lives in the client's environment, not in your fork.

## Configuration: no fork

Everything in `config.yaml` and `.env` is per-environment and carried by no one. Provider, sizing, domain, DNS, OCI source, alerting — all configuration. If a client's need is expressible here, it is free.

See [Configuration](../adopter/deploy/configuration.md) for the full schema.

## Helm value overrides: no fork

You can override the platform's Helm values for the **`mojaloop`** and **`mcm`** charts without forking, by placing files in the environment's `values/` directory. They layer over the platform defaults through an optional ConfigMap.

This covers a large amount of application-level tailoring — resource sizing, feature flags, chart-exposed settings — with zero maintenance burden, because the override lives in the client's environment.

Two limits, both worth knowing before you rely on it:

- **Only `mojaloop` and `mcm` are wired for overrides.** Tailoring any other chart this way is not currently possible — that need pushes you toward a fork, or toward [contributing the wiring upstream](../platform/index.md) so it becomes a no-fork option for everyone.
- **Flux substitution variables are not expanded** in these files — hardcode values.

See [Configuration → Helm value overrides](../adopter/deploy/configuration.md#helm-value-overrides).

## Forking: carried forever

When configuration and overrides genuinely cannot express the need — a new provider, a changed module, a service the distribution does not include — you fork and change the code. The mechanics are the [Platform guide](../platform/index.md): the same module pipeline, the same "add a provider / add a service" procedures.

What is different for you is the **cost model**. Every line you change in `src/` or `gitops/` is a line you reconcile against upstream at every update. A fork is not a one-time cost; it is a recurring one, paid at each rebase. This is why the discipline is to fork as narrowly as possible — change the least that meets the need, and prefer a clean addition (a new file, a new module) over an edit to an existing one, because additions rebase more cleanly than edits.

## Deciding

For any client requirement, walk down the layers and stop at the first that works:

1. **Can `config.yaml` / `.env` express it?** → configuration. Done, free.
2. **Is it a `mojaloop` or `mcm` chart value?** → value override. Done, free.
3. **Could it be either, if the wiring existed?** → consider [contributing the wiring upstream](../platform/index.md) so it becomes free — for you and everyone.
4. **Only then, fork** — and change the minimum.

The trap is reaching for a fork when a value override would do, because the fork is invisible today and expensive at every future upgrade. When in doubt, spend the effort finding a no-fork path before spending it on a fork.
