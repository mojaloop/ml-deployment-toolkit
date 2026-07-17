# Adding Providers

[docs](../index.md) / [platform](index.md) / Adding Providers

**Audiences:** platform engineer

This page covers the integration points for adding a new infrastructure provider to ML Deployment Toolkit. For the architectural rationale behind the provider model, see [provider model](../architecture/provider-model.md).

## What a new provider requires

Six integration points, in the order you should implement them.

### 1. Terraform module -- `src/modules/<provider>/` (new)

Create a new module that provisions a Kubernetes cluster on the target provider. The module must output `kubeconfig_path` -- this is the contract that the rest of the pipeline depends on:

```hcl
output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}
```

This is the main work. For managed Kubernetes providers (EKS, GKE, DOKS), the module typically creates a VPC, the cluster, and node pools. For Talos-based providers, it composes `talos-gen-config`, a VM module, and `talos-bootstrap`.

### 2. Root module -- `src/main.tf` (3 edits)

**Add a module block** with a count conditional that activates when the provider is selected:

```hcl
module "gcp" {
  count  = local.provider_name == "gcp" ? 1 : 0
  source = "./modules/gcp"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_pools         = try(module.config.deployment_template.node_pools, [])

  artifacts_path       = local.artifacts_path
  provider_config_path = "../config/providers/gcp/config.yaml"

  region = try(local.config_raw.infra.gcp.region, "us-central1")
}
```

**Add an entry to `provider_outputs`** so the kubeconfig is wired through:

```hcl
provider_outputs = {
  proxmox      = length(module.proxmox) > 0 ? module.proxmox[0] : null
  digitalocean = length(module.digitalocean) > 0 ? module.digitalocean[0] : null
  aws          = length(module.aws) > 0 ? module.aws[0] : null
  gcp          = length(module.gcp) > 0 ? module.gcp[0] : null     # <-- new
}
```

**Add to `flux_bootstrap` depends_on** so Flux waits for the cluster:

```hcl
module "flux_bootstrap" {
  depends_on = [
    module.proxmox,
    module.digitalocean,
    module.aws,
    module.gcp        # <-- new
  ]
}
```

### 3. Flux config conditionals -- `src/modules/flux-config/main.tf` (2 edits)

Two local variables control which gitops paths are deployed. Add the new provider to the relevant lists:

**`is_talos`** -- add here only if the provider uses Talos Linux (not managed Kubernetes):

```hcl
is_talos = contains(["proxmox", "openstack"], var.infra_provider)
```

Most managed providers (GCP, Azure) do not belong here. Only add to `is_talos` if the provider provisions Talos nodes.

**`has_vendor`** -- add here if the provider needs a vendor-specific gitops kustomization (CNI, LB, storage):

```hcl
has_vendor = contains(["proxmox", "openstack", "aws", "gcp"], var.infra_provider)
```

If the provider manages everything natively (unlikely), you can omit it from `has_vendor`.

### 4. Provider config -- `config/providers/<provider>/` (new)

Create two YAML files:

**`config.yaml`** -- provider-level defaults (VPC settings, image config, etc.):

```yaml
# config/providers/gcp/config.yaml
gcp:
  project: ""          # Set in environment config
  network_cidr: "10.0.0.0/16"
```

**`deployment-templates.yaml`** -- named cluster topologies with sizing:

```yaml
# config/providers/gcp/deployment-templates.yaml
templates:
  micro:
    node_pools:
      - name: default
        machine_type: e2-standard-4
        count: 2
  small:
    node_pools:
      - name: default
        machine_type: e2-standard-8
        count: 3
```

Adopters select a template via `template: <name>` in their environment's `config.yaml`.

### 5. Vendor kustomization -- `gitops/<provider>/` (new, if self-managed components)

Create a Kustomize root with provider-specific gap fillers -- whatever the cloud does not manage natively. For a managed provider like GCP, this is often minimal:

```yaml
# gitops/gcp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium/helmrelease.yaml    # If BYOCNI
```

For Talos-based providers, this includes Cilium, LB-IPAM, OpenEBS, and potentially more. The existing `gitops/talos/` directory covers Proxmox and OpenStack -- Talos-based providers share it rather than creating their own.

### 6. Terraform provider config -- `src/providers.tf` + Makefile

**Add provider block to `src/providers.tf`:**

```hcl
provider "google" {
  project = try(local.config_raw.infra.gcp.project, "")
  region  = try(local.config_raw.infra.gcp.region, "us-central1")
}
```

**Add provider version to `src/versions.tf`:**

```hcl
google = {
  source  = "hashicorp/google"
  version = "~> 5.0"
}
```

**Add credential mapping to Makefile `LOAD_ENV`** if the provider needs credentials beyond native env vars. Some providers (AWS, Proxmox) use native environment variables and need no Makefile changes.

## What you don't touch

These are shared across all providers and require no changes when adding a new provider:

- **`gitops/platform/`** -- metrics-server, external-dns, cert-manager, ESO
- **`gitops/platform-config/`** -- Gateways, wildcard TLS (uses `${gateway_class_name}` substitution)
- **`gitops/dns/`** -- DNS is an independent dimension from infrastructure provider
- **`gitops/cc*/`** -- Tooling Cluster services (Vault, Harbor, MinIO)
- **`gitops/env*/`** -- App Environment services (Mojaloop, auth, data)
- **`src/modules/flux-bootstrap/`** -- Flux controller installation (provider-agnostic)
- **`src/modules/flux-config/`** -- beyond the two conditional edits in step 3
- **`src/modules/config-loader/`** -- unless new config patterns are needed

## Known risk: is_talos coupling

The `is_talos` flag in `flux-config` currently serves double duty: it selects the `talos` vendor kustomization and also enables the self-hosted data layer (`env-data`). This means a managed Kubernetes provider that wants self-hosted databases (e.g., EKS with Percona instead of RDS) cannot express that today without also being listed in `is_talos`.

If your provider needs self-hosted databases on managed Kubernetes, you will need to refactor `is_talos` into two separate flags: one for vendor gitops selection and one for the data layer. See the architecture docs for discussion.

## Example: adding GCP step by step

GCP/GKE is a good reference because it is a managed Kubernetes provider where Google handles CNI, storage, and load balancing natively.

**Step 1.** Create `src/modules/gcp/` with VPC + GKE cluster + node pools. Output `kubeconfig_path`. Use the `aws/` module as a structural reference.

**Step 2.** Add the `module "gcp"` block to `src/main.tf`, add `gcp` to `provider_outputs`, and add `module.gcp` to `flux_bootstrap` depends_on.

**Step 3.** Add `"gcp"` to the `has_vendor` list in `src/modules/flux-config/main.tf`. Do not add to `is_talos` (GKE is managed Kubernetes). Set `gateway_class_name` to `gke-l7-regional-external-managed` in the environment config.

**Step 4.** Create `config/providers/gcp/config.yaml` and `deployment-templates.yaml` with project defaults and node pool templates.

**Step 5.** Create `gitops/gcp/` with a minimal kustomization. GKE manages CNI (Dataplane V2), storage (Persistent Disk CSI), and load balancing natively, so this directory may only need provider-specific CRDs or BackendConfigs.

**Step 6.** Add the `google` provider to `src/providers.tf` and `src/versions.tf`. GCP uses Application Default Credentials, so the Makefile may not need changes.

**Step 7.** Publish and test:

```bash
make push-gitops ENV=cc
make plan-apply ENV=gcp-dev
```
