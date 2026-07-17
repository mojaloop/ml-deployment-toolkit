# Known Issues (Platform)

[docs](../index.md) / [platform](index.md) / Known Issues

**Audiences:** platform engineer

Known issues encountered during platform development and artifact publishing. For deployment issues, see [adopter known issues](../adopter/known-issues.md). For runtime issues, see [operations known issues](../operations/known-issues.md).

---

### Cilium v1.18.8 BPF dead code elimination probe failure (Cilium, v1.18.8)

**Symptoms:** Cilium agent pods enter CrashLoopBackOff on clusters running Cilium v1.18.8. Agent logs show a BPF probe failure related to dead code elimination.

**Root cause:** Regression in Cilium v1.18.8's BPF dead code elimination feature probe. The probe incorrectly fails on certain kernel configurations, preventing the agent from starting.

**Fix/workaround:** Pin the Cilium HelmRelease to v1.18.7 in `gitops/talos/cilium/helmrelease.yaml`:

```yaml
chart:
  spec:
    chart: cilium
    version: "1.18.7"
```

**Prevention:** Never use semver ranges for Cilium in production -- always pin to a tested patch version. Test new Cilium versions in a non-production environment before promoting the artifact.

---

### Cilium major version upgrade -- CRD API version ordering (Cilium, v1.18.x to v1.19.x)

**Symptoms:** Cilium upgrade from v1.18.x to v1.19.x fails. Cilium pods crash or the Helm upgrade hangs. CRD validation errors appear in Flux HelmRelease status.

**Root cause:** Cilium CRDs shipped with v1.19.x list new API versions before old ones in the `spec.versions` array. During a rolling upgrade, existing resources validated against the old schema fail against the new CRD ordering, causing compatibility issues.

**Fix/workaround:** Two-push deployment:

1. **First push:** Update CRDs only. Push an artifact with the new Cilium CRDs but keep the Cilium HelmRelease version at v1.18.x. This lets the cluster accept both API versions.
2. **Second push:** Update the Cilium HelmRelease version to v1.19.x. The CRDs are already in place, so the upgrade proceeds cleanly.

In practice, this means two `make push-gitops` cycles with a reconciliation wait between them.

**Prevention:** Always perform major Cilium upgrades in two steps. Never combine CRD updates and application version changes in a single artifact push. Validate the CRD update has fully reconciled (`flux get kustomizations` shows ready) before pushing the version bump.

---

## Emergency operations reference

Key commands for incident response during platform operations. These apply to any Flux-managed resource, not just Cilium.

### Suspend and resume Flux reconciliation

Suspend a HelmRelease to stop Flux from reverting manual changes:

```bash
flux suspend helmrelease <name> -n flux-system
```

Resume when the fix is committed to the artifact:

```bash
flux resume helmrelease <name> -n flux-system
```

The same pattern works for Kustomizations:

```bash
flux suspend kustomization <name> -n flux-system
flux resume kustomization <name> -n flux-system
```

### Scale down workloads

Always suspend the owning Flux resource **before** scaling down. Otherwise Flux will immediately scale it back up.

```bash
# 1. Suspend the HelmRelease
flux suspend helmrelease mojaloop -n flux-system

# 2. Now scale down
kubectl scale deployment <name> -n mojaloop --replicas=0
```

### Force re-reconcile

After committing a fix to the artifact and pushing with `make push-gitops`, force Flux to pick it up immediately instead of waiting for the next interval:

```bash
flux reconcile source oci ml-gitops -n flux-system
flux reconcile kustomization <name> -n flux-system
```

### Resume in dependency order

When resuming after an incident that required suspending multiple kustomizations, resume in the same order as the `dependsOn` chain. For the Tooling Cluster:

```bash
flux resume kustomization platform -n flux-system
flux resume kustomization dns -n flux-system
flux resume kustomization platform-config -n flux-system
flux resume kustomization talos -n flux-system       # or aws, if managed
flux resume kustomization cc -n flux-system
flux resume kustomization cc-config -n flux-system
flux resume kustomization cc-routes -n flux-system
flux resume kustomization cc-observability -n flux-system
flux resume kustomization cc-observability-routes -n flux-system
```

For an App Environment (on-prem):

```bash
flux resume kustomization platform -n flux-system
flux resume kustomization dns -n flux-system
flux resume kustomization platform-config -n flux-system
flux resume kustomization talos -n flux-system
flux resume kustomization env -n flux-system
flux resume kustomization env-data -n flux-system
flux resume kustomization env-auth -n flux-system
flux resume kustomization env-auth-config -n flux-system
flux resume kustomization env-app -n flux-system
```

**Key principle:** Suspend before scaling. Resume in dependency order. Never resume a downstream kustomization before its dependencies are healthy.
