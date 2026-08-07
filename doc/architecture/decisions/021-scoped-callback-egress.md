# 021 — Callback egress policy scoped to the calling services

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 021 — Scoped callback egress

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer

## Context

Hub-to-participant callbacks must present the Hub's client certificate over mTLS. The Mojaloop services that make those calls speak plain HTTP; a CiliumNetworkPolicy redirects their outbound traffic into an Envoy listener that originates mTLS toward the participant, using certificates rendered by the Vault Agent.

The first version of that policy used an empty `endpointSelector`, applying to every pod in the `mojaloop` namespace. Cilium applied the redirect to *all* TCP 80/443 egress from the namespace — including traffic that was already HTTPS and had nothing to do with callbacks. Database backup uploads to object storage were forced through a plain-HTTP listener and failed; the visible symptoms (backup crash loops) pointed nowhere near the network policy that caused them.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Namespace-wide policy | One policy, no list to maintain | Captures unrelated HTTPS egress and breaks it; failures surface far from the cause |
| Per-pod opt-in annotations | Precise | Annotations live on workloads owned by the upstream chart; every chart upgrade risks losing them |
| **Selector scoped to the callback-making services** (chosen) | Only the intended traffic is redirected | The service list must be maintained by hand |

## Decision

The `dfsp-callback-egress` policy selects exactly the services that make outbound calls to participants: the notification handler, account lookup, and the two quoting services. All other egress from the namespace is untouched.

## Consequences

- **Unrelated outbound TLS works.** The backup-upload failure class is gone; the corresponding known-issue entry was retired, and deleting the policy is no longer a fix for anything — it now breaks callback mTLS.
- **The selector is a hand-maintained list.** A new service that starts calling participants must be added to it; until it is, its callbacks bypass the mTLS listener and fail at the participant's door, not the Hub's.
- **The redirect stays invisible to the applications.** Services keep speaking plain HTTP; certificate handling stays in one Envoy and one Vault Agent.
