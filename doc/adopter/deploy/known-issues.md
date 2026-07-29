# Known Issues — Deployment

[doc](../../index.md) / [adopter](../index.md) / [deploy](../index.md) / Known issues

**Audiences:** adopter (deploy)

Issues encountered while deploying. Runtime issues are in [Operate → Known issues](../operate/known-issues.md).

## Mojaloop migration fails with BackoffLimitExceeded on a fresh deploy

**Symptoms**

```
kubectl get helmrelease mojaloop -n flux-system
# False — InstallFailed
# "job moja-centralledger-service-migration failed: BackoffLimitExceeded"
```

**Root cause**

A race between the MySQL operator creating database users (7–10 minutes) and the Helm pre-install migration jobs. The migration starts before its user exists, fails with access-denied, and exhausts `backoffLimit: 1`.

**Fix**

Suspend and resume the HelmRelease once the users exist:

```bash
flux suspend helmrelease mojaloop -n flux-system
flux resume helmrelease mojaloop -n flux-system
kubectl get helmrelease mojaloop -n flux-system --watch
```

**Prevention**

- Wait ~10 minutes after `make plan-apply` before checking HelmRelease status
- Confirm the database is ready first — note the namespace is `data`:
  ```bash
  kubectl get pxc mojaloop-db -n data -o jsonpath='{.status.state}'
  ```
  It should report `ready`.

## Stale plan error on make apply

**Symptoms** — `make apply` fails reporting a stale plan.

**Root cause** — state changed between `make plan` and `make apply`.

**Fix** — use `make plan-apply`, which plans and applies in one step:

```bash
make plan-apply ENV=<env>
```

**Prevention** — always use `make plan-apply` unless the plan needs review first.

## OCIRepository not Ready

**Symptoms** — `kubectl get ocirepository -n flux-system` shows `Ready: False`.

**Root cause** — wrong OCI URL, missing credentials, or the registry is unreachable.

**Fix**

1. Check `artifact.url` in `config.yaml` matches the registry
2. Check `OCI_REPO_USERNAME` / `OCI_REPO_PASSWORD` in `.env`, and that they have read access
3. Test access directly:
   ```bash
   flux pull artifact <oci-url> --output /tmp/test
   ```
4. Re-apply the config stack: `make apply-config ENV=<env>`

## Kustomization stuck on "dependency not ready"

**Symptoms** — one or more Kustomizations wait indefinitely on a dependency.

**Root cause** — an upstream Kustomization failed, blocking everything behind it.

**Fix**

1. List them and find the **earliest** failing one — later failures are usually consequences:
   ```bash
   kubectl get kustomizations -n flux-system
   ```
2. Inspect it:
   ```bash
   kubectl describe kustomization <name> -n flux-system
   ```
3. Fix the root cause — usually missing secrets, DNS credentials, or a cert-manager issue.

The chain is `platform` → `dns` → `platform-config` → vendor → role layers. A failure early blocks all of it, so start at the front.
