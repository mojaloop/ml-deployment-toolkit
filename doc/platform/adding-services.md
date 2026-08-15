# Adding a Service

[doc](../index.md) / [platform](index.md) / Adding a service

**Audiences:** platform developer

Adding a platform service or a DNS provider to the distribution.

- [Where a service goes](#where-a-service-goes)
- [Adding a platform service](#adding-a-platform-service)
- [Wiring substitution values](#wiring-substitution-values)
- [Adding a DNS provider](#adding-a-dns-provider)
- [Health gating](#health-gating)

## Where a service goes

Which Kustomization a service belongs in follows from which clusters need it and when.

| Kustomization | For services that... |
|---------------|----------------------|
| `platform/` | Every cluster needs — cert-manager, ESO, external-dns, metrics-server, VPA, Goldilocks, reloader, the OpenTelemetry operator |
| `talos/` | Only self-managed clusters need — CNI, storage, LB-IPAM |
| `tooling*/` | Only the Tooling Cluster runs — registry, storage, observability backend |
| `hub*/` | Only a Hub runs — data layer, auth, Mojaloop |

Match the reconciliation stage to the dependency. A service needing the database goes in `hub-app` (which gates on the data layer); one needing nothing goes earlier. Placing it too early means it starts before its dependencies exist.

## Adding a platform service

Each service lives in its own subdirectory of the Kustomization root — `platform/cert-manager/`, `hub-auth/vault/` — holding its HelmRelease and its values file:

1. **Create `<root>/<service>/`** with the manifest — a `HelmRelease` referencing a `HelmRepository`, or plain YAML — as `<service>/helmrelease.yaml`.
2. **Put the chart's values in `<root>/values/<namespace>/<release>.yaml`** — never in `spec.values`. See the rule below. The `values/<namespace>/<release>.yaml` path suffix is the same one the template and environment layers use for the same release, so an override's base is always found by path.
3. **Register both in the root's `kustomization.yaml`** — the manifest under `resources:` (`- <service>/helmrelease.yaml`), and the values file as a `configMapGenerator` entry. A resource not listed there is silently not applied. This is the most common omission.
4. **Add a namespace** if the service needs its own — either a `Namespace` manifest or `install.createNamespace` on the HelmRelease, consistent with the neighbours.
5. **Add a route** if it needs external access — an `HTTPRoute` attaching to `gw-int` or `gw-ext`, in the appropriate routes Kustomization. See [Networking](../architecture/networking.md).

Keep it provider-agnostic. If the service needs a value that varies by environment, that value comes through substitution — never hardcode a domain or an endpoint.

### `spec.values` is never used

Flux merges a HelmRelease's inline `spec.values` *after* everything in `spec.valuesFrom`, so any value set inline cannot be overridden by an adopter. Every chart therefore ships its values in a ConfigMap listed first, with the adopter's override last:

```yaml
# <root>/values/<namespace>/<release>.yaml — plain chart values, no wrapper
ingress:
  host: "<service>.int.${DOMAIN}"
```

Tuning that varies by environment stays a literal default here (a template or an adopter overrides it through the chain); a `${UPPER_SNAKE}` token appears only for values `config.yaml` or `.env` actually parameterizes — a domain, an endpoint, a credential. There are no template-supplied variables.

```yaml
# in the HelmRelease — no spec.values anywhere
  valuesFrom:
    - kind: ConfigMap
      name: <release>-values                        # distribution defaults
      valuesKey: values.yaml
    - kind: ConfigMap
      name: <namespace>-<release>-values-template   # template layer
      valuesKey: values.yaml
      optional: true
    - kind: ConfigMap
      name: <namespace>-<release>-values-override   # adopter override twin
      valuesKey: values.yaml
      optional: true
    - kind: Secret
      name: <namespace>-<release>-values-override   # adopter override twin (secrets)
      valuesKey: values.yaml
      optional: true
```

Every HelmRelease's chain must **end with the three-layer tail, in that order** — the `<targetNamespace>-<release>-values-template` ConfigMap, then the override twins, ConfigMap then Secret, both named `<targetNamespace>-<release>-values-override`, all `optional: true`. Do not write the tail by hand: `tools/generate-valuesfrom.sh` splices it mechanically and is idempotent, and `check-valuesfrom` (run by `make check`) only verifies, so an incomplete chain fails before it ships. The distribution's own `<release>-values` ConfigMap naming is otherwise unchanged.

```yaml
# in the root's kustomization.yaml
configMapGenerator:
  - name: <release>-values
    namespace: flux-system
    files:
      - values.yaml=values/<namespace>/<release>.yaml
generatorOptions:
  disableNameSuffixHash: true
```

Three details matter. The generated ConfigMap must be in `flux-system`, where the HelmReleases live, because `valuesFrom` resolves in the HelmRelease's namespace. `disableNameSuffixHash: true` is required rather than stylistic — Kustomize does not rewrite name references inside a CRD, so a hashed name would leave `valuesFrom` pointing at a ConfigMap that does not exist, and the chart would quietly deploy on bare defaults. And `${UPPER_SNAKE}` substitution works normally inside the values file, because Flux renders it as part of the Kustomization.

A chart that puts values inline still works, so nothing fails loudly — it just silently removes that chart from the adopter's reach ([ADR-022](../architecture/decisions/022-helm-values-layering.md)). `grep -rn '^  values:' gitops/` should return nothing.

## Wiring substitution values

If the service needs an environment-specific value — a domain, an endpoint, a credential — it flows through the same path as everything else:

1. Add the field to the configuration if it is adopter-set
2. Carry it through `config-loader` and into `flux-config`, which writes it to `cluster-config` (non-secret) or `cluster-secrets` (secret) — the key name is `UPPER_SNAKE`, like every key in both objects
3. Reference it in the manifest with `${UPPER_SNAKE}`

Substitution tokens are bare `${UPPER_SNAKE}` and nothing else — no operators, no inline defaults (`${X:-y}` is not portable across the two engines). Both engines — Flux's `postBuild.substituteFrom` in the artifact layers, Terraform `templatefile` for environment-authored files — **fail hard on an undefined variable**, so a typo'd token stops the reconcile or the apply rather than passing through as an empty string. A literal `$` is escaped as `$${...}`, which both engines honour. `check-substitution` enforces token shape across the tree — including the environment directories — and `check-token-resolution` verifies, role-aware, that every token a manifest references is one the config stack defines for the roles that apply it, so a token added to a manifest without step 2 fails the check rather than the reconcile.

**The secret-placement rule.** Never substitute a token that resolves from `cluster-secrets` into a ConfigMap-shaped document — a secret value must not land in a ConfigMap. Secret-shaped resources carry substituted secret values under `stringData`. `check-secret-placement` enforces this.

See [Module pipeline → the boundary](module-pipeline.md#the-terraformflux-boundary). Do not have Terraform template the manifest directly; the substitution inputs are the interface.

## Adding a DNS provider

A DNS provider is a self-contained directory under `gitops/dns/<provider>/` containing the cert-manager issuer configuration and the external-dns setup for that provider.

The three existing providers — `route53`, `cloudflare`, `digitalocean` — are the templates. To add one:

1. Create `gitops/dns/<provider>/` mirroring an existing provider's structure
2. Configure the cert-manager `ClusterIssuer` DNS-01 solver for the provider
3. Configure `external-dns` for the provider
4. **Register the name in the `dns.provider` enum** in `config/schemas/environment.schema.json` — the enum is closed, and `make validate` rejects an unlisted provider
5. **Carry the credential through**: add its variable to `SECRET_KEYS` in the `Makefile` (or it never enters the secrets map) and to `dns_credentials` in `flux-config` (or it never reaches `cluster-secrets` for the manifests to substitute)
6. Document the credential and its environment variable

Steps 4–5 are the ones a half-added provider is missing — the manifests exist but the name fails validation, or the credential silently never arrives.

The `dns` Kustomization deploys `gitops/dns/${DNS_PROVIDER}/`, so the directory name must match the value adopters put in `dns.provider`. A DNS provider touches nothing in the infrastructure or application layers — that independence is the point.

## Health gating

If downstream Kustomizations depend on the new service being genuinely ready — not just applied — add a health check in `flux-config` so the chain waits for it.

This matters most for services others build on: a database, an operator, an identity component. The existing gates wait on operator readiness and on custom-resource status, not merely on a Deployment existing. A service that reports "applied" before it is usable will let the next stage start too early and fail — which is exactly the class of race the [reconciliation order](../architecture/system-overview.md#reconciliation-order) exists to prevent. If the service is a dependency, gate on what "ready" actually means for it.
