# 010 — Dual-realm Keycloak with Kratos OIDC

[doc](../../index.md) / [architecture](../index.md) / [decisions](./) / 010 — Dual-realm Keycloak

**Date:** 2026-03-31
**Status:** superseded by [014](014-ory-identity-stack.md)
**Audiences:** architect, platform developer

## Context

Two user populations needed separation: hub operators managing the switch, and participant staff managing their own institution's connection. MCM created clients and groups programmatically per participant, so it needed a realm it could manage without touching hub operator accounts.

## Decision

Two Keycloak realms — `hub-operators` and `dfsps` — with Ory Kratos in front as the session layer, configured with one OIDC provider per realm. Oathkeeper authenticated against Kratos session cookies, keeping API authorization realm-agnostic.

## Outcome

Superseded. Keycloak is no longer deployed. The population separation this record set out to achieve is now expressed as relationship tuples in Ory Keto rather than as separate realms, and machine identity moved to Ory Hydra.

See [ADR-014](014-ory-identity-stack.md) for the replacement and its rationale.

**Nothing in this record describes the running system.** It is retained because the requirement it identified — separating hub operators from participant staff, with programmatic per-participant management — still shapes the current design.
