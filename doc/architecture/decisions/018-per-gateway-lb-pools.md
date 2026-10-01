# 018 — Per-gateway LB-IPAM pools with selector labels

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 018 — Per-gateway LB-IPAM pools

**Date:** 2026-08-07
**Status:** accepted — supersedes [008](008-three-lb-architecture.md)
**Audiences:** architect, platform developer, adopter (deploy)

## Context

[ADR-008](008-three-lb-architecture.md) gave a Hub three LoadBalancer addresses drawn from one shared LB-IPAM range. Two pressures broke that model.

First, the FSPIOP mirror endpoint (`gw-intapi`) was promoted from riding on `gw-int` to its own gateway, so that it can be firewalled independently of the ops UIs — anything that reaches it can transact as any participant. That made four addresses, not three.

Second, a shared range assigns addresses in arrival order. Which gateway got which address depended on reconciliation timing, so border firewall rules and DNAT mappings could only be written *after* a deploy, and could silently change across a rebuild. Cilium LB-IPAM has no pool priority: a selectorless pool matches every LoadBalancer Service in the cluster, so mixing a shared pool with pinned addresses makes assignment nondeterministic.

The change was implemented in commit `4663cea` (2026-08-01); this record documents the decision retroactively.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Shared range (ADR-008's model) | One pool to size | Address-to-gateway mapping decided by reconciliation order; firewall rules only writable after deploy |
| Per-service pinned IPs via annotation | Predictable | Pins live on Services the distribution does not own (Cilium generates the Gateway Services); annotations fight the shared pool for the same range |
| **One single-address pool per gateway, matched by label** (chosen) | Every address known before the cluster exists; no ordering dependency | More pools to declare; a selectorless pool anywhere breaks determinism and must be forbidden |

## Decision

Each gateway owns a dedicated single-address `CiliumLoadBalancerIPPool`, selecting its Service by the label `lb-pool: <gateway>`. The label reaches the generated Service through the Gateway's `spec.infrastructure.labels`; the FSPIOP endpoint's plain LoadBalancer Service carries it directly.

The pools are declared in `config.yaml` under `cluster.lb_ipam.pools`. A Hub declares four — `gw-int`, `gw-ext`, `gw-extapi`, `gw-intapi`; a Tooling Cluster exactly two — `gw-int`, `gw-ext`. Plan-time preconditions enforce the shape: pools are required on self-managed infrastructure, `gw-extapi`/`gw-intapi` are rejected outside `role: hub`, `lan` addresses must be distinct from each other and from the cluster VIP, and duplicate `wan` addresses are rejected.

A pool may also declare a `wan` address, stating that the border firewall 1:1-DNATs that outside address to the pool's `lan` address. external-dns then publishes the `wan` address for everything attached to that gateway, via the `external-dns.alpha.kubernetes.io/target` annotation.

## Consequences

- **Every endpoint address is known before the cluster exists.** Firewall rules, DNAT mappings, and DNS expectations can be written up front and survive rebuilds.
- **Never add a selectorless pool.** It would match every LoadBalancer Service and reintroduce the nondeterminism this design removes.
- **The pools are the cluster's entire LB address supply.** A LoadBalancer Service that matches no pool stays `Pending` — new gateways need a new pool, deliberately.
- **A Hub needs four addresses, a Tooling Cluster two.** Breaking change against ADR-008's three; environments written for three fail the plan until `gw-intapi` is added.
- **`wan` shifts DNS, not routing.** LAN clients resolve the public address too and need hairpin NAT or split DNS to reach the gateway.

## Amendment (2026-09-30)
**Status:** accepted — amends the plan-time rule and the meaning of `wan` in [Decision](#decision) above.
Several gateways may share the **same** `wan` address. The original decision required duplicate `wan` values to be rejected at plan time; that precondition is removed. Repeating `wan` supports a single border reverse proxy (TLS SNI) that fronts multiple private LoadBalancer IPs while each pool keeps its own `lan`.
`wan` is the **border address that reaches the gateway's `lan`**, not only a 1:1 DNAT mapping. Adopters set `wan` **per pool** on the gateways that should appear in public DNS; pools without `wan` continue to publish `lan` as the DNS target (internal-only gateways).
When pools share a `wan`, the border proxy must route each public hostname (by SNI or equivalent) to the correct gateway `lan`. The hairpin / split-DNS caveat for LAN clients still applies to every pool that has `wan` set.
