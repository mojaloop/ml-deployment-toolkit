# Upgrading

[docs](../index.md) / [adopter](index.md) / Upgrading

**Audiences:** adopter (deploy)

This guide covers how to upgrade an existing ML Deployment Toolkit deployment. For architecture context on how OCI artifacts and Flux reconciliation work, see [GitOps structure](../architecture/gitops-structure.md).

## Upgrading platform services

The upgrade path depends on whether your environment pins a specific OCI artifact version or follows the `latest` tag.

### Option A -- automatic (latest tag)

No action needed. Flux polls the OCI source every 10 minutes. When the platform team publishes a new artifact, Flux detects the updated `latest` tag and applies changes automatically.

Monitor reconciliation after a known publish:

```bash
kubectl get kustomizations -n flux-system
```

All kustomizations should show `Ready: True` within a few minutes of the new artifact being available.

### Option B -- pinned version

When `oci.repo.version` is set to a specific tag in your environment config:

1. Update `oci.repo.version` in `config/environments/<env>/config.yaml` to the new version
2. Apply the change:
   ```bash
   make plan-apply ENV=<env>
   ```
3. Verify Flux reconciliation:
   ```bash
   kubectl get kustomizations -n flux-system
   ```

Pinning is recommended for production environments where you want explicit control over when changes roll out.

## Upgrading infrastructure

To change cluster topology, provider settings, or Flux version:

1. Edit `config/environments/<env>/config.yaml` with the desired changes
2. Review the execution plan:
   ```bash
   make plan ENV=<env>
   ```
3. Inspect the plan output carefully -- infrastructure changes can be disruptive (node replacements, VIP changes, etc.)
4. Apply:
   ```bash
   make apply ENV=<env>
   ```

## Upgrading Kubernetes version (on-prem)

Kubernetes and Talos versions are managed centrally in `config/definitions/workload-classes.yaml`. This is a platform-team change, not an adopter change.

After the platform team updates the workload classes and publishes a new IaC bundle:

1. Pull the updated bundle
2. Apply the change:
   ```bash
   make plan-apply ENV=<env>
   ```
   Terraform detects the version change and updates nodes accordingly.

On managed Kubernetes providers (AWS EKS, DigitalOcean DOKS), the Kubernetes version is specified in the provider configuration and follows the same `make plan-apply` workflow.

## Rollback

If an upgrade causes issues:

- **Platform services:** Revert `oci.repo.version` to the previous tag in `config/environments/<env>/config.yaml` and run `make plan-apply ENV=<env>`. Alternatively, the platform team can publish a fixed artifact.
- **Infrastructure:** Revert config changes in `config/environments/<env>/config.yaml` and run `make plan-apply ENV=<env>`.
- **Data layer:** See [backup and restore](../operations/backup-restore.md) for data recovery procedures.
