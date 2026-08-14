# Building Artifacts

[doc](../index.md) / [platform](index.md) / Building artifacts

**Audiences:** platform developer

Rendering pre-built manifests, then publishing, versioning, and promoting the GitOps OCI artifact.

- [What the artifact is](#what-the-artifact-is)
- [Rendering](#rendering)
- [Publishing](#publishing)
- [Versioning and promotion](#versioning-and-promotion)
- [Verifying](#verifying)

## What the artifact is

The GitOps artifact is the `gitops/` directory packaged as an OCI artifact and pushed to a registry. Flux pulls it and reconciles it — see [GitOps structure](../architecture/gitops-structure.md). Publishing is how a change to `gitops/` reaches any cluster.

Most of `gitops/` is authored by hand. Two pieces are **rendered** from upstream sources and committed, because they are consumed before Flux is running.

## Rendering

```bash
make render          # both
make render-thanos   # Thanos manifests from kube-thanos Jsonnet
make render-cilium   # Cilium bootstrap manifest from the Helm chart
```

**Thanos** is rendered from Jsonnet into `gitops/tooling-observability/thanos/`. Re-render it when bumping the Thanos version or changing its topology. Because these are raw rendered manifests rather than a HelmRelease, values like retention are baked in at render time — changing them means a re-render and a new artifact, not a config edit.

**Cilium** is rendered because it is fetched by Talos as an extra manifest at boot, before Flux exists. `make render-cilium` templates a minimal bootstrap manifest into `config/manifests/`. It carries a safety guard: if the render produces any `Secret` (which would mean private keys committed to git), the freshly written file is deleted and the target fails. Keep Hubble disabled in the render values so no TLS secrets are generated — the guard enforces this, and a render failure here usually means Hubble was enabled.

Thanos rendering needs `jsonnet`, `jb`, and `yq` — mikefarah/yq v4, not the Python `yq` from `apt` or `pip` ([Prerequisites → Tools](../adopter/deploy/prerequisites.md#tools)); the Cilium render needs `helm`.

## Publishing

```bash
make push-gitops ENV=<env>
```

This packages `gitops/` and pushes it to the registry in the environment's `artifact.url`, tagged with the current git SHA. It stamps the artifact with its git source and revision, so a published artifact is traceable to the exact commit that produced it. Only `make release` additionally moves the `latest` tag.

Publishing needs `OCI_REPO_USERNAME` / `OCI_REPO_PASSWORD` with push access — see [Prerequisites → OCI registry](../adopter/deploy/prerequisites.md#oci-registry).

To publish under an explicit version instead of the SHA:

```bash
make push-gitops ENV=<env> GITOPS_VERSION=v1.2.0
```

## Versioning and promotion

```bash
make release ENV=<env> TAG=v1.2.0
```

`release` is the versioned-publish path: it creates and pushes a git tag, publishes the artifact under that tag, and also tags it `latest`. `ENV=` is required — it selects the registry through the environment's `artifact.url`, like every artifact target. Use `release` for anything a downstream consumer will pin to — a tagged release is a git commit and an artifact digest that agree.

Run **`make check`** — the `tools/checks/` suite — before releasing. It is the pre-release gate: substitution tokens, `valuesFrom` chain completeness, secret placement, the provider interface, and tool versions all validate locally, and a release that skips it ships whatever the checks would have caught.

Consumers cannot follow `latest`: an environment's `artifact.version` must be a **pinned `vX.Y.Z`** — the schema rejects `latest` — and pinned versions are asserted at plan time. Every deployed cluster therefore names the exact release it runs, which is why the tagged-release discipline above matters.

To add a tag to an already-published artifact — promoting a tested build to a channel, for instance — name the published version explicitly:

```bash
make tag-gitops ENV=<env> GITOPS_VERSION=v1.2.0 TAG=stable
```

Without `GITOPS_VERSION`, the target tags the artifact matching the current working tree's git SHA — correct only when promoting the build just pushed from this checkout.

The promotion model is publish once, then move tags. Artifacts are immutable and content-addressed, so promoting `v1.2.0` to `stable` points the tag at the exact bytes already tested — there is no rebuild, and nothing can change between test and promotion.

List what exists:

```bash
make list-artifacts ENV=<env>
```

## Verifying

Before promoting, confirm the artifact contains what it should:

```bash
flux pull artifact oci://<repo>:<tag> --output /tmp/artifact \
  --creds "$OCI_REPO_USERNAME:$OCI_REPO_PASSWORD"   # omit --creds for a public registry
```

This pulls and unpacks the artifact, exposing the `gitops/` tree that clusters will actually reconcile. Doing this against a release candidate before tagging it `stable` catches a mis-publish before it reaches a consumer following that tag.

Which release a cluster runs is the adopter's choice, pinned in `artifact.version` — see [Upgrading](../adopter/deploy/upgrading.md). The platform developer's responsibility ends at publishing a correct, correctly-tagged artifact.
