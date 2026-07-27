# Known Issues — Platform

[doc](../index.md) / [platform](index.md) / Known issues

**Audiences:** platform developer

Build, render, and Flux issues at the platform level, plus the emergency operations to reach for when reconciliation goes wrong.

## Cilium render must keep Hubble disabled

`make render-cilium` refuses to write the bootstrap manifest if the render produces any `Secret` — because a committed Secret means private keys in git. Enabling Hubble in `rendering/cilium/values.yaml` generates TLS secrets and trips the guard.

**If the render fails with a Secret error,** confirm Hubble is disabled in the render values. Hubble runs fine in the cluster — it is configured through the Flux-reconciled `gitops/talos/cilium/` layer, not the bootstrap manifest. The bootstrap manifest is intentionally minimal; Flux applies the full configuration once the cluster is up.

## Rendered manifests need re-rendering on version bumps

Thanos and the Cilium bootstrap manifest are rendered from upstream sources and committed, not reconciled live. Bumping either version does nothing on its own; re-render afterwards:

```bash
make render-thanos      # after a Thanos change
make render-cilium CILIUM_VERSION=<version>   # after a Cilium bump
```

A version change that "did not take" is usually a missed render.

## Emergency operations

When reconciliation is misbehaving, these are the levers. They act on Flux, not on Terraform.

### Suspend and resume a HelmRelease

The standard remedy for a HelmRelease stuck on a transient failure — a dependency that was not ready:

```bash
flux suspend helmrelease <name> -n flux-system
flux resume helmrelease <name> -n flux-system
```

### Force a reconcile

Pull the latest artifact and re-apply without waiting for the poll interval:

```bash
flux reconcile source oci ml-gitops
flux reconcile kustomization <name> -n flux-system
```

### Resume in dependency order

After a broad suspend, resume from the front of the chain so each layer's dependencies are ready before it starts: `platform` → `dns` → `platform-config` → vendor → role layers. Resuming a late Kustomization first just makes it fail on a missing dependency.

### Find the real failure

A stalled chain usually has one root cause and several downstream symptoms. Always inspect the **earliest** failing Kustomization:

```bash
kubectl get kustomizations -n flux-system
kubectl describe kustomization <earliest-failing> -n flux-system
```

## See also

Deployment-time issues an adopter hits are in [Adopter → Deploy → Known issues](../adopter/deploy/known-issues.md); runtime issues are in [Adopter → Operate → Known issues](../adopter/operate/known-issues.md). Code-level defects and planned work are tracked in `discrepancies.md`.
