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

This is the whole reason [the customization surface](customization-surface.md) pushes so hard toward configuration and value overrides: those carry across upstream releases for free, because they are not in the fork at all. Everything kept out of the fork is a rebase the integrator never has to do.

## Rebasing on a release

Upstream publishes tagged releases. Rebase onto a release tag, not onto a moving branch — a tag is a fixed, tested point; a branch keeps moving.

The shape of a rebase:

1. **Pick the upstream release** to move to — a tag, not `main`.
2. **Rebase or merge the fork's changes onto it.** Narrow, additive changes should apply cleanly; edits to files upstream also changed are where conflicts land.
3. **Re-render** anything derived — Thanos and the Cilium bootstrap manifest — if their upstream versions moved. See [Building artifacts → rendering](../platform/building-artifacts.md#rendering).
4. **Verify.** This is the weak point — there is no test suite (see below), so verification is a real deployment to a lab environment and a walk through the [adopter verification](../adopter/deploy/deployment.md#verify-up-the-stack) and a test transaction.
5. **Publish** the new derivative version, encoding the upstream base in the tag.

## What breaks, and where to look

Upstream changes fall into a few classes, in rough order of how much attention they need:

| Change | Effect on the derivative | Where it shows |
|--------|---------------|----------------|
| Configuration schema change | An adopter-facing field moved or renamed | `config-loader`, the config schema |
| Substitution variable added/renamed | A manifest expects a value `flux-config` must now provide | `flux-config`, `cluster-config`/`cluster-secrets` |
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
- **Verify against a lab every time.** With no automated safety net (`discrepancies.md` item D3 — no CI or tests), a real deployment is the only proof the rebase held. Do not skip it because the diff looked clean.

The through-line: the cheapest divergence is the one that is not in the fork. Spend effort at customization time finding the no-fork path, and every upgrade for the life of the client relationship costs far less.
