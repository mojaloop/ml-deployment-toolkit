# Deployment

[docs](../index.md) / [adopter](index.md) / Deployment

**Audiences:** adopter (deploy)

Shared deployment workflow for all cluster types. For role-specific configuration and verification, see:

- [Deploy a Tooling Cluster (CC)](deployment-cc.md)
- [Deploy a Switch (SW)](deployment-sw.md)

For initial environment configuration, see [Configuration](configuration.md). For architecture context, see [System Overview](../architecture/system-overview.md).

---

## Initialize

Download providers and initialize Terraform modules:

```bash
make init ENV=<env>
```

Run this once for a new environment, or after changing providers or upgrading Terraform modules. The `init` step runs automatically as part of `plan` and `plan-apply`, so you rarely need to run it explicitly.

## Plan and apply

```bash
make plan ENV=<env>          # Create execution plan (saved to artifacts/)
make apply ENV=<env>         # Apply the saved plan
```

Or combine both steps to avoid stale plan errors:

```bash
make plan-apply ENV=<env>
```

The `plan-apply` target creates a plan and applies it immediately. This is the recommended workflow because a plan can become stale if infrastructure changes between `plan` and `apply`.

### What happens during apply

Terraform executes modules in order:

1. **config-loader** -- reads `config.yaml`, resolves profiles and placement
2. **Provider module** (proxmox, aws, or digitalocean) -- provisions the Kubernetes cluster
3. **flux-bootstrap** -- installs FluxCD controllers via Helm
4. **flux-config** -- creates OCIRepository, Kustomizations, ConfigMap, and Secret (only when `oci.repo.active: true`)

Once Flux is running, it reconciles the OCI artifact and deploys all gitops-managed services. Which kustomization roots are applied (Tooling Cluster vs Switch) is determined by `cluster.role` in `config.yaml`. This takes several minutes after Terraform completes.

---

## Verify

After `make apply` completes, run the shared checks below. Role-specific verification lives in the [CC](deployment-cc.md#verify) and [SW](deployment-sw.md#verify) deployment pages.

### Set KUBECONFIG

```bash
export KUBECONFIG=$(pwd)/artifacts/<env>/kubernetes/kubeconfig
```

### Check cluster health

```bash
# Nodes should be Ready
kubectl get nodes

# Flux controllers should be Running
kubectl get pods -n flux-system
```

### Check Flux reconciliation

```bash
# OCIRepository should show the artifact revision
kubectl get ocirepository -n flux-system

# All Kustomizations should be Ready
kubectl get kustomizations -n flux-system
```

If any Kustomization stays in `False` state for more than a few minutes, see [Troubleshooting](../operations/troubleshooting.md).

---

## Outputs

After a successful `make apply`, the following artifacts are produced:

| Artifact | Path | Description |
|----------|------|-------------|
| Terraform state | `artifacts/<env>/terraform/terraform.tfstate` | Full infrastructure state |
| Terraform plan | `artifacts/<env>/terraform/tfplan` | Last executed plan |
| Kubeconfig | `artifacts/<env>/kubernetes/kubeconfig` | Cluster access credentials |
| Talosconfig | `artifacts/<env>/talos-config/talosconfig` | Talos API credentials (on-prem only) |

Terraform also exposes these outputs:

| Output | Description |
|--------|-------------|
| `cluster_name` | The cluster name from config |
| `cluster_endpoint` | Kubernetes API endpoint (VIP for on-prem, managed endpoint for cloud) |
| `kubeconfig_path` | Absolute path to the kubeconfig file |
| `talosconfig_path` | Absolute path to talosconfig (on-prem only, null for cloud) |
| `flux_installed` | Whether FluxCD controllers are installed |
| `oci_repo_active` | Whether Flux OCI reconciliation is active |

View outputs with:

```bash
cd src && terraform output
```

---

## Commands reference

All commands run from the repository root. `ENV=` selects the environment (default: `cc`).

### Main commands

| Command | Description |
|---------|-------------|
| `make plan ENV=<env>` | Create Terraform execution plan (saved to `artifacts/<env>/terraform/tfplan`) |
| `make apply ENV=<env>` | Apply the saved plan. Fails if no plan exists. |
| `make plan-apply ENV=<env>` | Create plan and apply immediately. Recommended workflow. |

### Alternative apply commands

| Command | Description |
|---------|-------------|
| `make apply-direct ENV=<env>` | Apply directly without a saved plan (auto-approve). Skips the plan file. |
| `make apply-force ENV=<env>` | Alias for `plan-apply`. |

### Utility commands

| Command | Description |
|---------|-------------|
| `make init ENV=<env>` | Initialize Terraform (download providers, configure backend). Runs automatically with `plan` and `plan-apply`. |
| `make validate` | Validate Terraform configuration syntax. |
| `make fmt` | Format Terraform files recursively. |
| `make show` | Display current Terraform state. |
| `make list` | List all resources in Terraform state. |
| `make clean` | Remove all artifacts (`artifacts/` directory). |

### GitOps artifact commands

| Command | Description |
|---------|-------------|
| `make push-gitops ENV=<env>` | Push `gitops/` directory as OCI artifact. Version defaults to the current git SHA; also tagged `latest`. |
| `make push-gitops ENV=<env> GITOPS_VERSION=v1.0.0` | Push with an explicit version tag. |
| `make tag-gitops TAG=<tag>` | Add an additional tag to the current artifact version. |
| `make list-artifacts ENV=<env>` | List published OCI artifact versions. |

### Rendering commands

| Command | Description |
|---------|-------------|
| `make render` | Render all pre-rendered manifests (Jsonnet to YAML). |
| `make render-thanos` | Render Thanos manifests only. |

### Destroy commands

| Command | Description |
|---------|-------------|
| `make destroy ENV=<env>` | Destroy all infrastructure. 5-second safety delay before execution. |
| `make destroy-fast ENV=<env>` | Destroy without refreshing state first. Use when resources are already gone. 3-second safety delay. |

---

## Destroy

To tear down an environment:

```bash
make destroy ENV=<env>
```

This destroys all Terraform-managed infrastructure for the environment. There is a 5-second safety delay before execution -- press Ctrl+C to cancel.

If resources have already been deleted outside of Terraform (e.g., VMs manually removed), use the fast variant to skip the state refresh:

```bash
make destroy-fast ENV=<env>
```

Destroy does not remove the `artifacts/` directory. Run `make clean` separately to remove local artifacts.

**Warning:** Destroy is irreversible. For Tooling Clusters, this removes Vault (secrets), Harbor (cached images), and MinIO (backups). Ensure the recovery kit is stored offline before destroying a Tooling Cluster. See [Security](../architecture/security.md) for recovery kit details.
