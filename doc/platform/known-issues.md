# Known Issues — Platform

[doc](../index.md) / [platform](index.md) / Known issues

**Audiences:** platform developer

Build and render issues at the platform level.

### Cilium render fails on a generated Secret (render-cilium)

**Symptoms:** `make render-cilium` fails with a Secret error and no manifest is left behind.
**Root cause:** The render guard rejects any output containing a `Secret` — a committed Secret means private keys in git. Enabling Hubble in `rendering/cilium/values.yaml` generates TLS secrets and trips it.
**Fix/workaround:** Confirm Hubble is disabled in the render values. Hubble runs fine in the cluster — it is configured through the Flux-reconciled `gitops/talos/cilium/` layer, not the bootstrap manifest, which is intentionally minimal.
**Prevention:** Keep Hubble (and anything else that mints keys) out of the render values; the guard exists to catch it.

### A version bump "did not take" (rendered manifests)

**Symptoms:** Thanos or the Cilium bootstrap manifest still runs the old version after a bump.
**Root cause:** Both are rendered from upstream sources and committed, not reconciled live — bumping the version does nothing on its own.
**Fix/workaround:** Re-render and commit:

```bash
make render-thanos      # after a Thanos change
make render-cilium CILIUM_VERSION=<version>   # after a Cilium bump
```

**Prevention:** Treat `make render` as part of any upstream version bump.

## See also

Reconciliation emergencies — suspend/resume, forced reconciles, finding the earliest failure — are the operator's levers, owned by [Adopter → Operate → Troubleshooting](../adopter/operate/troubleshooting.md#flux-and-reconciliation). Deployment-time issues are in [Adopter → Deploy → Known issues](../adopter/deploy/known-issues.md); runtime issues in [Adopter → Operate → Known issues](../adopter/operate/known-issues.md).
