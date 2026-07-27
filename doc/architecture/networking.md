# Networking

[doc](../index.md) / [architecture](index.md) / Networking

**Audiences:** architect, platform developer, adopter

Ingress topology, the three load balancers, and how DNS and certificates are issued.

- [Three entry points](#three-entry-points)
- [What is on each gateway](#what-is-on-each-gateway)
- [The FSPIOP endpoint is not a gateway](#the-fspiop-endpoint-is-not-a-gateway)
- [Load balancer addresses](#load-balancer-addresses)
- [DNS](#dns)
- [Certificates](#certificates)

## Three entry points

A Hub exposes three independent load-balanced addresses. Each has a different audience and a different trust model — which is why they are separate rather than one gateway with routing rules ([ADR-008](decisions/008-three-lb-architecture.md)).

| Entry point | Hostname pattern | Audience | TLS |
|-------------|-----------------|----------|-----|
| `gw-int` | `*.int.${domain}` | In-house operations | Server TLS, Let's Encrypt |
| `gw-ext` | `*.ext.${domain}` | External parties | Server TLS, Let's Encrypt |
| `extapi` | `extapi.${domain}` | Participant FSPIOP traffic | **Mutual TLS**, scheme CA |

`gw-int` and `gw-ext` are Gateway API Gateways in `platform-system`. The FSPIOP endpoint is not — see [below](#the-fspiop-endpoint-is-not-a-gateway).

A Tooling Cluster uses the same two gateways, hosting its own services rather than Mojaloop's.

## What is on each gateway

### `gw-int` — internal operations

| Host | Service |
|------|---------|
| `mcm.int` | Connection Manager UI and API — HubOps onboarding |
| `finance-portal.int` | Finance Portal |
| `auth.int` | Kratos self-service — login, recovery, account settings |
| `vault.int` | Vault UI |
| `flux.int` | Flux Operator UI |
| `hubble.int` | Cilium Hubble network observability |
| `goldilocks.int` | Resource recommendations |
| `ttk.int`, `ttk-backend.int` | Testing Toolkit |
| `simulator.int` | Simulator |
| `settlement.int` | Settlement API |
| `tx-requests.int` | Transaction requests API |
| `intapi.int` | FSPIOP mirror without mTLS — internal testing only |

On a Tooling Cluster: `harbor.int`, `minio.int`, `s3.int`, `grafana.int`, `loki.int`, `tempo.int`, `thanos.int`.

`intapi.int` deserves a warning: it exposes the same FSPIOP paths as the participant endpoint with **no client certificate requirement**. It exists for internal testing. Anything that can reach it can transact as any participant.

### `gw-ext` — external parties

Exactly two hosts:

| Host | Service |
|------|---------|
| `mcm.ext` | Connection Manager API — path prefix `/pm4mlapi`, rewritten to `/api` |
| `hydra.ext` | OAuth2 token endpoint and JWKS |

Participants authenticate at `hydra.ext` and manage their enrolment through `mcm.ext`.

> **Target state.** Participants — human and machine — reach MCM through `gw-ext`; `gw-int` is for in-house HubOps only. The MCM UI and Kratos self-service currently resolve to `.int` hosts. Tracked in `discrepancies.md`.

## The FSPIOP endpoint is not a gateway

`extapi.${domain}` is a standalone Envoy deployment behind its own LoadBalancer service. It does not use Gateway API, and no HTTPRoute points at it.

```mermaid
flowchart LR
    p["Participant"] -->|"mTLS :443"| lb["LoadBalancer"]
    lb --> e["Envoy<br/>extapi"]
    e -->|"HTTP :80"| svc["Mojaloop<br/>services"]
```

**Why.** Cilium's L7 load balancing runs on an east-west BPF path that requires pod identities. North-south traffic originating outside the cluster has none, so CiliumEnvoyConfig cannot terminate it ([ADR-004](decisions/004-standalone-envoy-inbound-mtls.md)).

The service is named `cilium-gateway-gw-extapi`, which is misleading — it is a plain LoadBalancer service, not a Cilium-managed gateway. The name is historical.

Envoy requires a client certificate on every connection and routes by path prefix to account lookup, quoting, the ML API adapter, the bulk adapter, and transaction requests. Certificates and the trust bundle are hot-reloaded from watched directories, so enrolling a participant neither restarts Envoy nor drops connections.

## Load balancer addresses

On self-hosted infrastructure, Cilium LB-IPAM assigns addresses from a pool the adopter defines, announced on the local network via L2.

```yaml
app:
  lb_ipam:
    range: "192.168.0.211-192.168.0.213"
```

**A Hub needs three addresses** — `gw-int`, `gw-ext`, and `extapi`. **A Tooling Cluster needs two** — it has no FSPIOP endpoint.

The range must sit outside the local DHCP scope. Overlap produces intermittent, hard-to-diagnose failures as addresses are handed out twice.

## DNS

`external-dns` watches Gateways and Services and reconciles records automatically. The operator never pre-creates records for Hub services — hand-created records cause ownership conflicts.

Two record shapes are produced:

- **Wildcards** for the gateways — `*.int.${domain}` and `*.ext.${domain}`
- **A single A record** for the FSPIOP endpoint, from an annotation on its service

Note that `extapi.${domain}` sits at the apex level, not under `.int` or `.ext`. It is not covered by either wildcard.

Participant FQDNs are the participant's own responsibility, in their own zone. The Hub never creates records for them, and each participant needs an individual record — there is no wildcard on that side.

Supported DNS providers: Route53, Cloudflare, DigitalOcean. The choice is independent of the infrastructure provider.

## Certificates

Public-facing certificates come from Let's Encrypt via cert-manager, using **DNS-01** challenges ([ADR-011](decisions/011-dns01-over-http01.md)).

DNS-01 rather than HTTP-01 because wildcard certificates require it, and because it works before any ingress path is reachable — which matters during bootstrap, when the cluster is not yet serving traffic.

The FSPIOP endpoint certificate is the exception: issued by Vault against the scheme CA, 30-day lifetime, renewed at 15 days. See [Security](security.md#certificate-authorities) for why the two PKIs are separate and [Participant mTLS](participant-mtls.md) for the participant certificate lifecycle.
