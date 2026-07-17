# Building Artifacts

[docs](../index.md) / [platform](index.md) / Building Artifacts

**Audiences:** platform engineer, system integrator

This page covers the OCI artifact lifecycle: authentication, building, publishing, versioning, and promotion. For the architectural rationale behind OCI-based distribution, see [GitOps structure](../architecture/gitops-structure.md).

## Authentication

The Makefile handles OCI registry login using credentials from your environment's `.env` file. For GHCR, generate a token with package read/write scopes:

```bash
gh auth refresh -s read:packages,write:packages
gh auth token
```

Add the token to your environment's `.env`:

```bash
OCI_REPO_USERNAME=<github-username>
OCI_REPO_PASSWORD=<token-from-above>
```

For CI/CD pipelines, use `GITHUB_TOKEN` (in GitHub Actions) or a fine-grained personal access token with `read:packages` and `write:packages` permissions.

## Push an artifact

```bash
make push-gitops ENV=cc                        # Git SHA version
make push-gitops ENV=cc GITOPS_VERSION=v1.0.0  # Explicit version
make tag-gitops ENV=cc TAG=stable              # Tag existing version
make list-artifacts ENV=cc                     # List published versions
```

What `push-gitops` does:

1. Packages the entire `gitops/` directory as an OCI artifact
2. Authenticates using `OCI_REPO_USERNAME` and `OCI_REPO_PASSWORD` from `.env`
3. Pushes to the `oci.repo.url` configured in your environment's `config.yaml`
4. Tags with the git SHA (or explicit `GITOPS_VERSION`) plus `latest`

## OCI registry URL

The registry URL is configured in `config.yaml` under `oci.repo.url`. Format: `oci://<registry>/<owner>/<package>`.

Examples:

| Registry | URL |
|----------|-----|
| GHCR | `oci://ghcr.io/mojaloop/ml-gitops` |
| Harbor (self-hosted) | `oci://harbor.example.com/mojaloop/ml-gitops` |
| ECR | `oci://123456789.dkr.ecr.us-east-1.amazonaws.com/ml-gitops` |

## Version management

| Strategy | When to use | Example |
|----------|-------------|---------|
| Git SHA (default) | Development, iteration | `make push-gitops ENV=cc` produces `a1b2c3d` |
| Semantic version | Releases, milestones | `make push-gitops ENV=cc GITOPS_VERSION=v1.0.0` |
| `latest` tag | Always applied automatically | Points to the most recent push |

Adopters pin their Flux `OCIRepository` to `latest` (continuous delivery) or a specific version (controlled upgrades).

## Promoting versions

To promote a version (e.g., mark a SHA as stable for production):

```bash
make tag-gitops ENV=cc TAG=stable
```

This tags the current `GITOPS_VERSION` (default: git SHA) with the given tag. Use this to implement promotion workflows like `dev` -> `staging` -> `stable`.

## Rendering pre-build artifacts

Some components require pre-rendering before publishing:

```bash
make render              # Render all pre-build artifacts
make render-thanos       # Render Thanos manifests only
make render-cilium       # Render Cilium bootstrap manifest only
```

### Thanos (Jsonnet to YAML)

Thanos manifests are rendered from kube-thanos Jsonnet (`rendering/thanos/`). Rendered output lands in `gitops/cc-observability/thanos/` and should be committed before running `push-gitops`.

### Cilium bootstrap manifest (Helm to YAML)

Talos installs Cilium during node bootstrap via `cluster.extraManifests` (see `config/patches/talos/patch-cilium-install.yaml`), fetching the rendered manifest from this repository over `raw.githubusercontent.com`. The render uses a minimal, standalone values file (`rendering/cilium/values.yaml`) — just enough for nodes to reach `Ready`. Once the cluster is up, Flux reconciles the full Cilium configuration from `gitops/talos/cilium/helmrelease.yaml` (Hubble, Gateway API, L2 announcements, metrics).

```bash
make render-cilium                        # Render the default chart version
make render-cilium CILIUM_VERSION=1.19.4  # Render a specific chart version
```

What `render-cilium` does:

1. Prepends `rendering/cilium/namespace.yaml` — the `cilium` namespace with privileged Pod Security labels, which Talos requires and `helm template` does not emit
2. Renders the chart with `helm template` using `rendering/cilium/values.yaml`
3. Fails if the output contains any `Secret` — this repository is public, so no private keys may be committed (this is also why Hubble must stay disabled in the bootstrap values)
4. Writes `config/manifests/cilium-<version>.yaml`

To upgrade Cilium:

1. `make render-cilium CILIUM_VERSION=<new-version>`
2. Update the manifest URL in `config/patches/talos/patch-cilium-install.yaml` to the new filename
3. Bump the chart version in `gitops/talos/cilium/helmrelease.yaml` to match
4. Commit **and push to `main`** — Talos fetches the manifest from GitHub at node bootstrap, so until the commit is on `origin/main` the URL returns 404 and new nodes cannot install CNI (they stay `NotReady`)

## Verify artifact contents

Pull a published artifact locally to inspect its contents:

```bash
flux pull artifact oci://ghcr.io/mojaloop/ml-gitops:latest --output ./tmp-artifact
ls -la ./tmp-artifact/
```

This mirrors the exact file tree that Flux will reconcile on the cluster.

## CI/CD integration

Example GitHub Actions workflow that publishes on every push to `main` and on release:

```yaml
name: Publish GitOps Artifact
on:
  push:
    branches: [main]
    paths: ['gitops/**']
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: fluxcd/flux2/action@main
      - env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          echo "$GITHUB_TOKEN" | flux login ghcr.io --username=flux --password-stdin
          VERSION="${GITHUB_REF_NAME}"
          if [ "${{ github.event_name }}" = "push" ]; then VERSION="${GITHUB_SHA::7}"; fi
          flux push artifact oci://ghcr.io/${{ github.repository_owner }}/ml-gitops:${VERSION} \
            --path=./gitops \
            --source="${{ github.server_url }}/${{ github.repository }}" \
            --revision="${GITHUB_SHA::7}"
          flux tag artifact oci://ghcr.io/${{ github.repository_owner }}/ml-gitops:${VERSION} \
            --tag=latest
```

For self-hosted Harbor registries, replace the GHCR URL and credentials with your Harbor instance details.
