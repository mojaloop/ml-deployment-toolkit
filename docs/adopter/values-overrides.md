# Helm Value Overrides

Files placed in `config/environments/<env>/values/` are **optional deployer
overrides** that layer on top of the platform team's base Helm values shipped
in the OCI gitops artifact.

Mechanics: each file is loaded by Terraform, materialized as a ConfigMap in
`flux-system`, and referenced by the corresponding HelmRelease via `valuesFrom`
with `optional: true`. Merge order (later wins, same as `helm install -f a -f b`):

1. Chart defaults
2. Platform HelmRelease inline `values:` (after Flux postBuild substitution)
3. **This file** (deployer override)

A missing file is a no-op — the HelmRelease applies with platform defaults only.

## Recognized files

| File              | Chart    | HelmRelease            | ConfigMap                  |
|-------------------|----------|------------------------|----------------------------|
| `mojaloop.yaml`   | mojaloop | `env-app/mojaloop`     | `mojaloop-values-override` |
| `mcm.yaml`        | mcm      | `env-app/mcm`          | `mcm-values-override`      |

## Notes

- Contents are taken verbatim. `${...}` Flux substitution variables are **not**
  expanded inside these files — hardcode the values you need.
- After editing, run `make plan-apply ENV=<env>` to update the ConfigMap;
  Flux picks up the change on the next HelmRelease reconcile (~10m).
- Delete the file (or leave empty) to drop back to platform defaults.
- The `values/` directory is git-ignored (per-environment, may contain
  deployment-specific tuning).
