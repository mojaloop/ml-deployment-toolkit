# 008 — Three LoadBalancer IPs per Hub

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 008 — Three LoadBalancer IPs per Hub

**Date:** 2026-03-31
**Status:** superseded by [018](018-per-gateway-lb-pools.md)
**Audiences:** architect, platform developer, network engineer

> **Superseded in count and mechanism, kept in principle.** [ADR-018](018-per-gateway-lb-pools.md) promoted the FSPIOP mirror to its own gateway (`gw-intapi`) — a Hub now needs **four** addresses — and replaced the shared LB-IPAM range with one single-address, label-selected pool per gateway, so every address is known before the cluster exists. The DNS consequence below is also outdated: records are published per host, and `extapi.${domain}` is a single apex record, not a wildcard. What this record decided — that traffic classes with different trust models get separate load balancers rather than one gateway with routing rules — still holds. Read it for the reasoning; read ADR-018 for the current layout.

## Context

Each Hub needs to serve three distinct traffic classes with different security requirements:

1. **Internal ops traffic** (monitoring dashboards, internal APIs) — no external exposure needed.
2. **Participant non-mTLS traffic** (MCM API, OAuth2 token endpoint) — TLS termination at the gateway, public-facing.
3. **DFSP FSPIOP traffic** — mutual TLS required, each DFSP presents a client certificate.

Gateway API (the Kubernetes-native ingress standard) does not support `tls.mode: Mutual`, so mTLS cannot be handled by a standard Gateway resource. Per ADR-004, inbound mTLS requires a standalone Envoy Deployment with its own LoadBalancer Service.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Two LBs (mTLS on gw-ext) | Fewer IPs, simpler config | Gateway API cannot configure mTLS; would require non-standard annotations or custom patches that break portability |
| Three LBs (gw-int, gw-ext, gw-extapi) | Clean separation per security class, each LB has a single TLS mode, Gateway API standard for non-mTLS | Requires 3 LB IPs from the pool, 3 DNS records |
| Single LB with SNI routing | One IP for everything | Complex SNI-based routing, mixes security contexts on one endpoint, operational complexity |

## Decision

Three LoadBalancer Services per Hub:

| LoadBalancer | Gateway/Controller | Traffic class | TLS mode |
|-------------|-------------------|--------------|----------|
| `cilium-gateway-gw-int` | Cilium Gateway (`gw-int`) | Internal ops (monitoring, internal APIs) | TLS termination (wildcard cert on `*.int.${domain}`) |
| `cilium-gateway-gw-ext` | Cilium Gateway (`gw-ext`) | Participant non-mTLS (MCM API, OAuth2) | TLS termination (wildcard cert on `*.ext.${domain}`) |
| `cilium-gateway-gw-extapi` | Standalone Envoy Deployment | DFSP FSPIOP (mTLS) | Mutual TLS (client cert verification) |

## Consequences

- **3 LB IPs required.** On-prem (Cilium LB-IPAM) must allocate 3 IPs from the pool. Cloud providers allocate NLBs automatically.
- **Clear security boundary.** Each LoadBalancer serves exactly one security class. No risk of misconfiguration exposing mTLS-only endpoints without client cert verification.
- **3 DNS wildcard records.** `*.int.${domain}`, `*.ext.${domain}`, and `*.extapi.${domain}` (or specific FSPIOP hostnames) point to their respective LB IPs.
- **Independent scaling.** The extapi Envoy Deployment can be scaled independently of the Cilium Gateway pods.
- **On-prem IP budget.** Small on-prem deployments must plan for at least 3 IPs in the LB-IPAM pool per Hub, plus additional IPs for the Tooling Cluster.
