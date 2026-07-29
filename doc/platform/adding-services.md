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
| `platform/` | Every cluster needs — cert-manager, ESO, external-dns, metrics-server |
| `talos/` | Only self-managed clusters need — CNI, storage, LB-IPAM |
| `cc*/` | Only the Tooling Cluster runs — registry, storage, observability backend |
| `env*/` | Only a Hub runs — data layer, auth, Mojaloop |

Match the reconciliation stage to the dependency. A service needing the database goes in `env-app` (which gates on the data layer); one needing nothing goes earlier. Placing it too early means it starts before its dependencies exist.

## Adding a platform service

A service is a HelmRelease (or raw manifests) added to the right Kustomization directory:

1. **Add the manifest** — a `HelmRelease` referencing a `HelmRepository`, or plain YAML, in the chosen Kustomization directory.
2. **Put the chart's values in `<release>-values.yaml`** beside the HelmRelease — never in `spec.values`. See the rule below.
3. **Register both in that directory's `kustomization.yaml`** — the manifest under `resources:`, and the values file as a `configMapGenerator` entry. A resource not listed there is silently not applied. This is the most common omission.
4. **Add a namespace** if the service needs its own — either a `Namespace` manifest or `install.createNamespace` on the HelmRelease, consistent with the neighbours.
5. **Add a route** if it needs external access — an `HTTPRoute` attaching to `gw-int` or `gw-ext`, in the appropriate routes Kustomization. See [Networking](../architecture/networking.md).

Keep it provider-agnostic. If the service needs a value that varies by environment, that value comes through substitution — never hardcode a domain or an endpoint.

### `spec.values` is never used

Flux merges a HelmRelease's inline `spec.values` *after* everything in `spec.valuesFrom`, so any value set inline cannot be overridden by an adopter. Every chart therefore ships its values in a ConfigMap listed first, with the adopter's override last:

```yaml
# <release>-values.yaml, beside the HelmRelease — plain chart values, no wrapper
replicaCount: ${some_template_key}
```

```yaml
# in the HelmRelease — no spec.values anywhere
  valuesFrom:
    - kind: ConfigMap
      name: <release>-values            # distribution defaults
      valuesKey: values.yaml
    - kind: ConfigMap
      name: <release>-values-override   # adopter — merged last, wins
      valuesKey: values.yaml
      optional: true
```

```yaml
# in the directory's kustomization.yaml
configMapGenerator:
  - name: <release>-values
    namespace: flux-system
    files:
      - values.yaml=<release>-values.yaml
generatorOptions:
  disableNameSuffixHash: true
```

Three details matter. The generated ConfigMap must be in `flux-system`, where the HelmReleases live, because `valuesFrom` resolves in the HelmRelease's namespace. `disableNameSuffixHash: true` is required rather than stylistic — Kustomize does not rewrite name references inside a CRD, so a hashed name would leave `valuesFrom` pointing at a ConfigMap that does not exist, and the chart would quietly deploy on bare defaults. And `${...}` substitution works normally inside the values file, because Flux renders it as part of the Kustomization.

A chart that puts values inline still works, so nothing fails to alert you — it just silently removes that chart from the adopter's reach. `grep -rn '^  values:' gitops/` should return nothing.

## Wiring substitution values

If the service needs an environment-specific value — a domain, an endpoint, a credential — it flows through the same path as everything else:

1. Add the field to the configuration if it is adopter-set
2. Carry it through `config-loader` and into `flux-config`, which writes it to `cluster-config` (non-secret) or `cluster-secrets` (secret)
3. Reference it in the manifest with `${...}`

See [Module pipeline → the boundary](module-pipeline.md#the-terraformflux-boundary). Do not have Terraform template the manifest directly; the substitution inputs are the interface.

## Adding a DNS provider

A DNS provider is a self-contained directory under `gitops/dns/<provider>/` containing the cert-manager issuer configuration and the external-dns setup for that provider.

The three existing providers — `route53`, `cloudflare`, `digitalocean` — are the templates. To add one:

1. Create `gitops/dns/<provider>/` mirroring an existing provider's structure
2. Configure the cert-manager `ClusterIssuer` DNS-01 solver for the provider
3. Configure `external-dns` for the provider
4. Document the credential and its environment variable

The `dns` Kustomization deploys `gitops/dns/${dns_provider}/`, so the directory name must match the value adopters put in `dns.provider`. A DNS provider touches nothing in the infrastructure or application layers — that independence is the point.

## Health gating

If downstream Kustomizations depend on the new service being genuinely ready — not just applied — add a health check in `flux-config` so the chain waits for it.

This matters most for services others build on: a database, an operator, an identity component. The existing gates wait on operator readiness and on custom-resource status, not merely on a Deployment existing. A service that reports "applied" before it is usable will let the next stage start too early and fail — which is exactly the class of race the [reconciliation order](../architecture/system-overview.md#reconciliation-order) exists to prevent. If the service is a dependency, gate on what "ready" actually means for it.
