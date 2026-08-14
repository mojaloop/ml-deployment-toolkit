# Publishing the Derivative Artifact

[doc](../index.md) / [integrator](index.md) / Publishing

**Audiences:** system integrator

Publishing the tailored distribution under the integrator's own identity, so clients consume it exactly as they would consume the upstream one.

- [The model](#the-model)
- [Fork and set the registry](#fork-and-set-the-registry)
- [Publish](#publish)
- [Provenance](#provenance)
- [How the client consumes it](#how-the-client-consumes-it)

## The model

The integrator publishes the derivative the same way upstream publishes its artifact — an OCI artifact in a registry — but under the integrator's registry and versioning. The client points their `artifact.url` at the integrator's registry and deploys with the standard workflow. Nothing about their experience changes; they just consume the derivative artifact instead of upstream's.

This is what "customize without disconnecting" means in practice: the client uses the same tooling, the same commands, the same upgrade path — the only difference is whose registry the artifact comes from.

The publishing mechanics are the [Platform guide → Building artifacts](../platform/building-artifacts.md); this page is what is specific to publishing a derivative.

## Fork and set the registry

Fork the repository, make the [narrowest necessary changes](customization-surface.md#forking-carried-forever), and point publishing at the integrator's own registry. A derivative is forked *public* software, maintained visibly as such — the fork is the published thing, not a quietly patched clone; on an unmodified clone, `make check-pristine` is what verifies no accidental derivative has crept in. The client's `config.yaml` will reference the integrator's registry in its `artifact` section:

```yaml
artifact:
  url: "oci://<registry>/<distribution>"
  version: "v1.2.0"
```

`artifact.version` must be a pinned `vX.Y.Z` — the schema rejects `latest` — so every client deployment names the exact derivative release it runs. Keep the derivative's release tags legible against their upstream base — record which upstream release each derivative version was built on — because at rebase time the integrator needs to know which upstream release a published artifact corresponds to.

## Publish

Run `make check` first — the local `tools/checks/` suite is the pre-release gate, and a derivative inherits it unchanged. Then:

```bash
make release ENV=<env> TAG=<version>
```

`release` tags the commit, publishes the artifact to the registry in that environment's `artifact.url`, and moves `latest`. The fork inherits the whole publishing pipeline unchanged, so this works exactly as it does upstream — see [Building artifacts → versioning and promotion](../platform/building-artifacts.md#versioning-and-promotion).

Promote tested builds by moving tags rather than rebuilding:

```bash
make tag-gitops ENV=<env> GITOPS_VERSION=<version> TAG=stable
```

Because artifacts are immutable and content-addressed, promoting a tested version to a client's channel points at the exact bytes the integrator verified — nothing changes between the integrator's testing and the client's deployment.

## Provenance

`make release` stamps each artifact with its git source URL and exact commit revision. For a derivative this is more than a nicety:

- **The integrator can prove what a client is running** — the artifact digest maps to a specific commit in the fork.
- **The integrator can trace it back to an upstream base** — with a version scheme that encodes the upstream release, a published artifact identifies both the integrator's changes and their upstream base.
- **A client's incident is diagnosable** — the running artifact identifies the exact code, the integrator's and upstream's, that produced it.

This is the one piece of derivative-maintenance infrastructure that already works well. Lean on it: never ship a client an artifact whose provenance the integrator cannot reconstruct.

## How the client consumes it

Identically to consuming upstream. The client sets `artifact.url` to the integrator's registry, provides pull credentials if it is private, and runs the standard [adopter deploy workflow](../adopter/deploy/deployment.md). Flux reconciles the derivative artifact the same way it would reconcile upstream's.

The client is an adopter — hand them the [Adopter guide](../adopter/index.md) for deploying and operating. The integrator's responsibility is publishing a correct, well-versioned, provenance-stamped artifact; the client's is deploying it. The clean seam between the two is what keeps a derivative maintainable on both sides.
