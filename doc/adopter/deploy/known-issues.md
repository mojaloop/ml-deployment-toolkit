# Known Issues — Deployment

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Known issues

**Audiences:** adopter (deploy)

Issues encountered while deploying. Runtime issues are in [Operate → Known issues](../operate/known-issues.md).

### Stale plan error on make apply (Terraform)

**Symptoms:** `make apply` fails reporting a stale plan.
**Root cause:** Infrastructure state changed between `make plan` and `make apply` — the saved infra plan no longer matches reality. The config stack is unaffected: `make apply` re-plans it after infra applies.
**Fix/workaround:** Re-plan and apply:

```bash
make plan ENV=<env> && make apply ENV=<env>
```

**Prevention:** Apply soon after planning, or use `make plan-apply ENV=<env>` when there is no plan to review — it chains plan and apply with nothing in between.

### OCIRepository not Ready (Flux)

**Symptoms:** `kubectl get ocirepository -n flux-system` shows `Ready: False`.
**Root cause:** Wrong OCI URL, missing credentials, or the registry is unreachable.
**Fix/workaround:**

1. Check `artifact.url` in `config.yaml` matches the registry
2. Check `OCI_REPO_USERNAME` / `OCI_REPO_PASSWORD` in `.env`, and that they have read access
3. Test access directly:
   ```bash
   flux pull artifact <oci-url> --output /tmp/test
   ```
4. Re-apply the config stack: `make apply-config ENV=<env>`

**Prevention:** Validate the artifact URL against the registry before the first deploy.

### Kustomization stuck on "dependency not ready" (Flux)

**Symptoms:** One or more Kustomizations wait indefinitely on a dependency.
**Root cause:** An upstream Kustomization failed, blocking everything behind it ([ADR-019](../../architecture/decisions/019-health-gated-reconciliation.md)).
**Fix/workaround:**

1. List them and find the **earliest** failing one — later failures are usually consequences:
   ```bash
   kubectl get kustomizations -n flux-system
   ```
2. Inspect it:
   ```bash
   kubectl describe kustomization <name> -n flux-system
   ```
3. Fix the root cause — usually missing secrets, DNS credentials, or a cert-manager issue.

**Prevention:** The chain is `platform` → `dns` → `platform-config` → vendor → role layers. A failure early blocks all of it, so start at the front.
