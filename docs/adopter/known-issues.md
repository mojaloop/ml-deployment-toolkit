# Known Issues (Deployment)

[docs](../index.md) / [adopter](index.md) / Known Issues

**Audiences:** adopter (deploy)

Known issues encountered during deployment. For runtime operational issues, see [operations known issues](../operations/known-issues.md).

---

### Mojaloop migration fails with BackoffLimitExceeded (fresh deploy)

**Symptoms:**

```
kubectl get helmrelease mojaloop -n flux-system
# Status: False - InstallFailed
# Message: "failed pre-install: job moja-centralledger-service-migration failed: BackoffLimitExceeded"
```

**Root cause:**
Race condition between PXC operator user creation (~7-10 minutes) and Helm pre-install migration jobs. Migration jobs start before database users exist, fail with "Access denied", and exhaust `backoffLimit: 1`.

**Fix/workaround:**
Suspend and resume the HelmRelease to trigger a retry (users exist by now):

```bash
flux suspend helmrelease mojaloop -n flux-system
flux resume helmrelease mojaloop -n flux-system
kubectl get helmrelease mojaloop -n flux-system --watch
```

**Prevention:**

- Wait ~10 minutes after `make apply` before checking HelmRelease statuses
- Check PXC readiness first: `kubectl get pxc mojaloop-db -n mojaloop -o jsonpath='{.status.state}'` -- it should report `ready`
- The `env-data` kustomization has a CEL health check that gates `env-app`, but the HelmRelease timeout may still be shorter than PXC initialization

---

### Stale plan error on make apply

**Symptoms:**
`make apply` fails with a stale plan error.

**Root cause:**
State changed between `make plan` and `make apply` (e.g., another apply ran, or cloud resources drifted).

**Fix/workaround:**
Use `make plan-apply` which plans and applies in one step:

```bash
make plan-apply ENV=<env>
```

**Prevention:**
Always use `make plan-apply` unless you need to review the plan separately. If you do use separate plan/apply, run them in quick succession.

---

### Flux OCIRepository not ready

**Symptoms:**
`kubectl get ocirepositories -n flux-system` shows `Ready: False`.

**Root cause:**
Wrong OCI URL, missing credentials, or network issue reaching the registry.

**Fix/workaround:**

1. Verify `oci.repo.url` in `config/environments/<env>/config.yaml` matches the actual registry
2. Check that `config/environments/<env>/.env` has correct `OCI_REPO_USERNAME` and `OCI_REPO_PASSWORD`
3. For private registries, ensure the credentials have read access to the artifact
4. Re-apply:
   ```bash
   make plan-apply ENV=<env>
   ```

**Prevention:**
Test OCI access manually before deploying:

```bash
flux pull artifact <oci-url> --output /tmp/test
```

---

### Kustomization stuck on dependency not ready

**Symptoms:**
`kubectl get kustomizations -n flux-system` shows one or more kustomizations in a `not ready` state, waiting on a dependency.

**Root cause:**
An upstream kustomization (e.g., `platform` or `dns`) has errors that block all downstream kustomizations in the dependency chain.

**Fix/workaround:**

1. List all kustomizations to see the dependency chain:
   ```bash
   kubectl get kustomizations -n flux-system
   ```
2. Find the first failing kustomization -- it is usually `platform` or `dns`
3. Inspect its events for the specific error:
   ```bash
   kubectl describe kustomization <name> -n flux-system
   ```
4. Fix the root cause (usually missing secrets, DNS credentials, or cert-manager issues)

**Prevention:**
Verify DNS credentials and OCI credentials are correct in `config/environments/<env>/.env` before deploying. The dependency chain is: `platform` -> `dns` -> `platform-config` -> vendor-specific -> role-specific. A failure early in the chain blocks everything downstream.
