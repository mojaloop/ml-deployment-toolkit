# Publishing Your Artifact

[doc](../index.md) / [integrator](index.md) / Publishing

**Audiences:** system integrator

Publishing your tailored distribution under your own identity, so clients consume it exactly as they would consume the upstream one.

- [The model](#the-model)
- [Fork and set your registry](#fork-and-set-your-registry)
- [Publish](#publish)
- [Provenance](#provenance)
- [How your client consumes it](#how-your-client-consumes-it)

## The model

Your derivative is published the same way the upstream artifact is — an OCI artifact in a registry — but under your registry and your versioning. The client points their `oci.repo.url` at yours and deploys with the standard workflow. Nothing about their experience changes; they just consume your artifact instead of upstream's.

This is what "customize without disconnecting" means in practice: the client uses the same tooling, the same commands, the same upgrade path — the only difference is whose registry the artifact comes from.

The publishing mechanics are the [Platform guide → Building artifacts](../platform/building-artifacts.md); this page is what is specific to publishing a derivative.

## Fork and set your registry

Fork the repository, make your [narrowest necessary changes](customization-surface.md#forking-carried-forever), and point publishing at your own registry. The client's `config.yaml` will reference this URL:

```yaml
oci:
  repo:
    url: "oci://<your-registry>/<your-distribution>"
    version: "v1.0.0-acme"
```

Use a versioning scheme that makes your derivative and its upstream base legible — encoding the upstream version you built from into your tag saves you at rebase time, when you need to know which upstream release a published artifact corresponds to.

## Publish

```bash
make release TAG=<your-version>
```

`release` tags the commit, publishes the artifact to your registry, and moves `latest`. Your fork inherits the whole publishing pipeline unchanged, so this works exactly as it does upstream — see [Building artifacts → versioning and promotion](../platform/building-artifacts.md#versioning-and-promotion).

Promote tested builds by moving tags rather than rebuilding:

```bash
make tag-gitops TAG=stable
```

Because artifacts are immutable and content-addressed, promoting a tested version to a client's channel points at the exact bytes you verified — nothing changes between your testing and their deployment.

## Provenance

`make release` stamps each artifact with its git source URL and exact commit revision. For a derivative this is more than a nicety:

- **You can prove what a client is running** — the artifact digest maps to a specific commit in your fork.
- **You can trace it back to an upstream base** — with a version scheme that encodes the upstream release, a published artifact tells you both what you changed and what you changed it from.
- **A client's incident is diagnosable** — the running artifact identifies the exact code, yours and upstream's, that produced it.

This is the one piece of derivative-maintenance infrastructure that already works well. Lean on it: never ship a client an artifact whose provenance you cannot reconstruct.

## How your client consumes it

Identically to consuming upstream. They set `oci.repo.url` to your registry, provide pull credentials if it is private, and run the standard [adopter deploy workflow](../adopter/deploy/deployment.md). Flux reconciles your artifact the same way it would reconcile upstream's.

Your client is an adopter — hand them the [Adopter guide](../adopter/index.md) for deploying and operating. Your responsibility is publishing a correct, well-versioned, provenance-stamped artifact; theirs is deploying it. The clean seam between the two is what keeps a derivative maintainable on both sides.
