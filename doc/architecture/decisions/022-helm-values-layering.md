# 022 — Helm values layered through valuesFrom, never inline

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 022 — Helm values layering

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer, system integrator

## Context

An adopter must be able to override any chart value without forking the distribution. Flux offers two places to put values on a HelmRelease: inline `spec.values`, and a `valuesFrom` list of ConfigMaps merged in order, later entries overwriting earlier ones — with inline `spec.values` merged **after** the whole list. Anything the distribution writes inline therefore beats anything an adopter can supply without editing the manifest itself.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Inline `spec.values` per HelmRelease | Values visible in the manifest | The distribution's values are unbeatable; every adopter override is a fork |
| Kustomize patches on the HelmRelease | No fork | Patch-merging structured values is fragile, and the adopter must know the manifest's internal layout |
| **`valuesFrom` chain, distribution first, adopter last** (chosen) | Chart defaults → distribution → adopter, later wins; overriding a distribution value is the normal case, not a fight | The no-inline rule must hold for every chart, forever |

## Decision

Every HelmRelease draws values exclusively through `valuesFrom`: the distribution's values ship as a `<name>-values` ConfigMap listed first, and an optional `<name>-values-override` ConfigMap is listed last. No HelmRelease uses inline `spec.values`; `grep -rn '^  values:' gitops/` returning nothing is the invariant.

The override ConfigMap is generated from the adopter's `environments/<env>/values/<name>.yaml`. Override files are templated over a fixed, small variable set; an unknown `${name}` fails the apply, and credentials are excluded — override files are for values, not secrets.

## Consequences

- **The adopter's file always wins**, including over values the distribution also sets — that is the intended precedence, not a conflict.
- **A chart that puts values inline silently removes itself from the adopter's reach.** Nothing fails; the override is simply ignored. New charts must follow the pattern, and the grep invariant is the check.
- **Distribution values live in ConfigMaps, not in HelmRelease manifests** — one mechanism carries both layers.
- **Override templating is deliberately narrow.** The variable set stays small so override files remain portable across environments; secrets never pass through this path.
