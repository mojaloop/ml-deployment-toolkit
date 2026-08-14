# Staying Upstream

[doc](../index.md) / [integrator](index.md) / Staying upstream

**Audiences:** system integrator

Keeping the derivative current as upstream moves — the recurring cost of a fork, and how to keep it low.

- [The recurring cost](#the-recurring-cost)
- [Rebasing on a release](#rebasing-on-a-release)
- [What breaks, and where to look](#what-breaks-and-where-to-look)
- [Keeping the cost down](#keeping-the-cost-down)

## The recurring cost

A fork is not paid for once. Each upstream release the integrator adopts demands reconciling the fork's changes against it, and the effort of that reconciliation is proportional to how much the fork diverged. A one-file addition rebases in minutes; a dozen edits scattered across shared modules is a project each time.

This is the whole reason [the customization surface](customization-surface.md) pushes so hard toward the environment layer: everything in `../environments/<env>/` — configuration, value overrides, patches, placement — carries across upstream releases for free, because it is not in the fork at all. Everything kept out of the fork is a rebase the integrator never has to do.

The contrast is sharp on the no-fork side. Where a client runs a **pristine clone at a release tag**, an upstream upgrade is a *checkout* of the next tag, never a rebase — `make check-pristine` verifies the clone is clean and at an exact tag, and the environment's `dtk_version` is asserted against that tag at plan time. Only a fork pays the reconciliation cost described below; a derivative is forked public software, and the fork is maintained visibly as its own repository with its own tags.

## Rebasing on a release

Rebase onto a **fixed upstream point**, never onto a moving branch. Once upstream publishes release tags, that point is a tag; until then, it is a specific upstream commit, recorded in the derivative's version tag so the base stays identifiable.

The shape of a rebase:

1. **Pick the upstream point** to move to — a release tag or a recorded commit, not `main`.
2. **Rebase or merge the fork's changes onto it.** Narrow, additive changes should apply cleanly; edits to files upstream also changed are where conflicts land.
3. **Re-render** anything derived — Thanos and the Cilium bootstrap manifest — if their upstream versions moved. See [Building artifacts → rendering](../platform/building-artifacts.md#rendering).
4. **Verify.** Run `make check` first — the `tools/checks/` suite validates substitution tokens, `valuesFrom` chains, secret placement, the provider interface, and tool versions locally, and catches a whole class of rebase damage before anything deploys. It is not a substitute for the real thing: there is no hosted CI, so verification proper is a real deployment to a lab environment, a walk through the [adopter verification](../adopter/deploy/deployment.md#verify-up-the-stack), and a test transaction.
5. **Publish** the new derivative version, encoding the upstream base in the tag.

## What breaks, and where to look

Upstream changes fall into a few classes, in rough order of how much attention they need:

| Change | Effect on the derivative | Where it shows |
|--------|---------------|----------------|
| Configuration schema change | An adopter-facing field moved or renamed | `config-loader`, the config schema |
| Substitution variable added/renamed | A manifest expects a value `flux-config` must now provide | `flux-config`, `cluster-config`/`cluster-secrets` |
| Provider interface change | A forked or added `params.yaml` must define the new `P_*` symbol | `config/templates/<provider>/params.yaml`, `check-interface` |
| A shared manifest the fork also edited | Merge conflict | Wherever the fork diverged |
| A rendered source version bump | Stale committed manifest | Re-render |
| A new health gate or reconciliation reorder | A fork-added service may need gating too | `flux-config` |

The substitution interface is the one to watch most closely. Because it is the [narrow contract between Terraform and Flux](../platform/module-pipeline.md#the-terraformflux-boundary), an upstream change there is small in the diff but can break reconciliation if the fork provides values through that channel.

## Keeping the cost down

Everything here reduces to a few habits:

- **Prefer configuration and value overrides** — they rebase for free.
- **Prefer additions over edits.** A new file or module conflicts far less than a changed line in a shared one.
- **Contribute genuinely general improvements upstream.** If a change would help more than the one client — a value-override wiring, a provider, a fix — [upstreaming it](../platform/index.md) removes it from the fork permanently. The best rebase is the one the integrator deleted the need for.
- **Rebase often, in small steps.** Skipping several releases compounds conflicts; adopting each one keeps every rebase small.
- **Verify against a lab every time.** `make check` runs locally and catches the mechanical breakage, but a real deployment is the only proof the rebase held. Do not skip it because the diff looked clean and the checks passed.

The through-line: the cheapest divergence is the one that is not in the fork. Spend effort at customization time finding the no-fork path, and every upgrade for the life of the client relationship costs far less.
