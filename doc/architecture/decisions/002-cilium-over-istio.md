# 002 — Cilium for all networking over Istio service mesh

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 002 — Cilium for all networking over Istio service mesh

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform developer

## Context

Mojaloop requires CNI networking, Gateway API ingress, network policies, and mutual TLS for DFSP FSPIOP traffic. The prior implementation (SW002) used Istio Ambient Mode (ztunnel + waypoint proxies) layered on top of Cilium CNI. This added significant operational complexity and resource overhead — two separate data planes (Cilium eBPF + Istio ztunnel) for overlapping concerns.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Istio Ambient Mode (ztunnel + waypoint) | Mature mTLS, full L7 policy | Two data planes (Cilium + ztunnel), 6+ extra pods, complex debugging, waypoint per-namespace overhead |
| Cilium (CNI + Gateway API + CiliumEnvoyConfig) | Already the CNI — zero additional pods for Gateway API, eBPF-native network policy, CEC for mTLS | CEC east/west limitation for inbound external traffic (see ADR-004), smaller Gateway API ecosystem |
| Linkerd | Lightweight sidecar mesh, simple operations | Requires sidecar injection, separate CNI still needed, smaller community than Cilium/Istio |

## Decision

Cilium as the unified networking layer for CNI, Gateway API, network policies, and DFSP mTLS. Since Cilium is already the CNI on all providers, enabling its Gateway API controller and using CiliumEnvoyConfig for mTLS adds zero additional pods to the cluster.

- **Gateway API:** Enabled via Cilium Helm values (`gatewayAPI.enabled: true`). Creates the `cilium` GatewayClass automatically.
- **Outbound mTLS:** CiliumEnvoyConfig on Cilium's existing Envoy DaemonSet handles mTLS origination for hub-to-DFSP callbacks (east/west path, pod-to-pod).
- **Inbound mTLS:** Standalone Envoy Deployment (see ADR-004) after discovering CEC's east/west limitation for external traffic.

## Consequences

- **Zero service mesh overhead.** No additional pods, sidecars, or control planes beyond what Cilium already provides.
- **Single data plane.** eBPF (L3/L4) + Envoy (L7) in one system, simplifying debugging and operations.
- **Two-phase Cilium deployment required for Talos.** Talos cannot run Helm during provisioning, so Cilium must be pre-rendered for bootstrap (Phase 1) then managed by Flux HelmRelease (Phase 2). See ADR-006.
- **CEC has east/west limitation for inbound traffic.** Cilium v1.18 classifies all CEC `spec.services` listeners as east/west in BPF, causing external traffic (no Cilium pod identity) to be rejected. This led to ADR-004 (standalone Envoy for inbound mTLS).
- **Outbound mTLS via CEC works well.** The east/west path is correct for pod-to-pod traffic originating from Mojaloop services to DFSP endpoints.
