# 020 — Vault KV engine version 1

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 020 — Vault KV v1

**Date:** 2026-08-07
**Status:** accepted
**Audiences:** architect, platform developer

## Context

MCM (the Connection Manager) stores participant material in Vault through its own client, which addresses secrets as `secret/mcm/...`. Vault's KV v2 engine inserts a `data/` segment into every API path (`secret/data/mcm/...`); a client that does not know about it receives a 403. MCM's client predates KV v2 and does not add the segment, so on a v2 mount every participant creation fails with a permission error that looks like a policy problem and is not.

The client lives in the upstream `connection-manager-api`; the distribution consumes its image and cannot patch the path handling without forking.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| KV v2 + fork the MCM client | Versioned secrets, soft delete | A fork of an upstream service for one path segment, carried forever |
| KV v2 + a path-rewriting proxy in front of Vault | No fork | A proxy in the credential path is a new failure mode and a new attack surface, to gain features MCM never uses |
| **KV v1** (chosen) | MCM works as shipped | No secret versioning or soft delete on this mount |

## Decision

The `secret/` mount MCM uses is KV **version 1**. The mount version is part of the contract with the MCM image and must not be upgraded while MCM's client writes unversioned paths.

## Consequences

- **Participant secrets on this mount have no version history and no soft delete.** An overwrite is final; recovery is from Vault snapshots, not from KV versions.
- **"Upgrading" the mount breaks participant creation with a misleading 403.** The failure appears on the next enrolment, not at upgrade time.
- **Revisit when the upstream client changes.** If MCM's Vault client gains KV v2 path handling, this record is the anchor to reconsider from.
