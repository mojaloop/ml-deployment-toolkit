# 010 — Dual-realm Keycloak with Kratos OIDC

[docs](../../index.md) / [architecture](../index.md) / [decisions](./) / 010 — Dual-realm Keycloak with Kratos OIDC

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform engineer, security engineer

## Context

Mojaloop serves two distinct user populations with different security requirements and lifecycle management:

1. **Hub operators** -- admin staff managing the switch, accessing the Finance Portal and operational tools. Managed centrally by the hub.
2. **DFSP users** -- staff at participating financial institutions, accessing MCM (Mojaloop Connection Manager) and DFSP-specific portals. Managed per-DFSP, with onboarding via email invitation.

These populations need separate identity stores, password policies, and client registrations. MCM's backend (`KeycloakService.js`) programmatically creates clients and groups in Keycloak for each onboarded DFSP, requiring a dedicated realm it can manage without affecting hub operator accounts.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Single Keycloak realm | Simpler config, one realm to manage | Mixes hub operators and DFSP users, MCM's programmatic client management could affect hub operator clients, no clean separation of password policies |
| Two Keycloak realms (hub-operators, dfsps) | Clean separation, independent policies, MCM manages only the dfsps realm | Two realms to configure, Kratos needs two OIDC providers, login page shows two buttons |
| Separate identity providers (Keycloak + external IdP) | Full isolation | Operational complexity of running two different identity systems |

## Decision

Two Keycloak realms with Kratos as the session management layer:

| Realm | Users | Purpose | Managed by |
|-------|-------|---------|------------|
| `hub-operators` | Hub admin staff | Finance Portal, operational dashboards | Hub admin (manual) |
| `dfsps` | DFSP users | MCM portal, DFSP-facing services | MCM backend (programmatic) + Keycloak admin (initial setup) |

Ory Kratos is configured with two OIDC providers (`id: hub-operators` and `id: dfsps`), each pointing to its respective Keycloak realm. The login page displays both options. Oathkeeper uses the `cookie_session` authenticator against Kratos session cookies, making API auth realm-agnostic.

MCM UI configuration uses `loginProvider: keycloak`, which intentionally does not match either Kratos OIDC provider id, preventing auto-selection and ensuring users see both login buttons.

## Consequences

- **Clean user population separation.** Hub operators and DFSP users have independent password policies, session settings, and client registrations.
- **MCM backend operates only on `dfsps` realm.** Programmatic DFSP onboarding (group creation, client registration, user invitation) cannot accidentally affect hub operator accounts.
- **Realm import is one-shot.** The Keycloak operator's `KeycloakRealmImport` uses `SKIP` strategy for existing realms. Changes to running realms must also be applied via the Keycloak admin API. The declarative YAML ensures correctness only for fresh deployments.
- **SMTP required for DFSP onboarding.** Keycloak's `dfsps` realm sends invitation emails to DFSP users, requiring SMTP configuration (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`).
- **Two login buttons.** Users must choose their realm on the login page. This is intentional -- it prevents a hub operator from accidentally authenticating against the DFSP realm (or vice versa).
