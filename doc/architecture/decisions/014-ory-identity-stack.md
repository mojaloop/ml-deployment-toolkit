# 014 — Ory as the complete identity and access stack

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 014 — Ory identity stack

**Date:** 2026-07-21
**Status:** accepted
**Audiences:** architect, platform developer, security engineer

Supersedes [ADR-010](010-dual-realm-keycloak.md).

## Context

The platform needs four things from identity and access:

1. **Human identity** — hub operators and participant staff, with self-service activation, login, and password recovery
2. **Machine identity** — participant agents authenticating to the MCM API without a human present
3. **Authorization** — fine-grained decisions such as *may this user read this participant's credentials?*
4. **Enforcement** — one place where every protected API is checked

The previous design used Keycloak for 1 and 2, and Kratos as a session layer in front of it. That produced two identity systems for one job: Keycloak owned the accounts, Kratos owned the sessions, and authorization was implicit in realm membership and client scopes.

Three problems drove the change.

**Authorization could not express what the scheme needed.** Realm membership is coarse. The requirement *"a hub administrator may manage a participant's certificates but may never read that participant's client secret"* has no natural expression in realm-and-client terms — it is a relationship between a subject and a specific object, not a role.

**Two systems overlapped.** Kratos and Keycloak both modelled users. Every identity question required knowing which system was authoritative for that field, and account lifecycle spanned both.

**Realm import was one-shot.** The Keycloak operator's import skipped existing realms, so declarative configuration was correct only on a fresh deployment. Changes to a running system had to be applied through the admin API — GitOps in name only.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Keep Keycloak, add a policy engine | Least disruption; Keycloak is widely understood | Three systems instead of two; still two user stores; realm import still one-shot |
| Keycloak only, drop Kratos | One system; mature admin UI | No relationship-based authorization; self-service flows need custom work; realm import problem remains |
| **Ory only — Kratos, Hydra, Keto, Oathkeeper** | One vendor, four sharp tools; authorization as code; every component declaratively configured | Four components to run; smaller operational community; Keto's model is unfamiliar to most operators |
| Ory plus an external IdP for humans | Enterprise SSO integration | Defers rather than solves the authorization problem |

## Decision

Adopt Ory for all four responsibilities, and remove Keycloak.

| Component | Owns |
|-----------|------|
| **Kratos** | Human identity — accounts, sessions, activation, recovery |
| **Hydra** | Machine identity — OAuth2 `client_credentials`, JWT issuance |
| **Keto** | Authorization — relationship tuples, permissions as code |
| **Oathkeeper** | Enforcement — identity-aware proxy in front of every protected API |

Three choices within that are load-bearing:

**Sessions resolve to the Kratos identity UUID, not the email address.** Email is mutable; identity is not. Authorization tuples reference the UUID, so changing a user's email cannot silently revoke their access.

**Permissions are defined as code**, in a single Keto namespace definition shipped with the artifact, rather than configured per deployment. Roles are shipped as `MojaloopRole` resources.

**`credentialsAccess` deliberately has no hub-admin traversal.** Unlike `view` and `manage`, which hub administrators inherit, access to a participant's own client credentials is granted to members of that participant alone. The hub creates the account; the participant generates and holds its own secret. This is the requirement that motivated relationship-based authorization in the first place — it is not expressible as a role.

## Consequences

**Authorization is reviewable.** Permissions live in one file, in the artifact, and change through the same review path as any other code. This is what realm configuration was not.

**The hub cannot hold participant secrets.** A structural guarantee rather than a policy, which changes the onboarding choreography: credential generation is necessarily a participant-side action. See [Participant integration](../participant-integration.md#the-choreography).

**Four components instead of one.** More moving parts, four databases, and a stack most operators will not have run before. The Ory components are individually simple, but the combination has a real learning cost — mitigated by each having a single, clearly-bounded job.

**No admin UI comparable to Keycloak's.** Day-to-day identity operations are API-driven or handled through MCM and the Finance Portal. Operators expecting a Keycloak-style console will not find one.

**Token audience is not validated.** The Mojaloop MCM client omits the `audience` parameter, so requiring it would reject every machine call. Trust rests on issuer and signature. Worth revisiting if the client changes.

**Migration was one-way.** Keycloak realms were not exported, and no rollback path exists. Remnants of the previous design survive in the repository — an empty namespace, a stale dashboard, unused Terraform variables — pending cleanup.

## Addendum (2026-08-26) — IAM as a swappable unit

The Ory stack originally shipped inside the combined `hub-auth` Kustomization,
entangled with Vault. The gitops layer now splits it into `hub-vault` (secrets
infrastructure) and `hub-iam` / `hub-iam-config` (the Ory stack and its
bootstrap), a pure refactor with no workload change. The point is isolation:
IAM is one swappable unit behind a Vault it merely consumes, so a later
migration to the upstream `mojaloop-iam` chart — or any other IAM packaging —
replaces `hub-iam` without touching secrets infrastructure. See
[Gitops structure](../gitops-structure.md).
