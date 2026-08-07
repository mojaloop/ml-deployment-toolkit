# 004 — Standalone Envoy Deployment for inbound DFSP mTLS

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 004 — Standalone Envoy Deployment for inbound DFSP mTLS

**Date:** 2026-03-31
**Status:** accepted
**Audiences:** architect, platform developer, security engineer

## Context

DFSPs (Digital Financial Service Providers) connect to the Mojaloop hub via mTLS for FSPIOP API traffic. Each DFSP presents a client certificate signed by a trusted CA, and the hub must verify it before routing traffic to the FSPIOP API handlers. The initial design attempted to use CiliumEnvoyConfig (CEC) for both inbound and outbound mTLS, keeping the entire mTLS data plane within Cilium's existing Envoy DaemonSet.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| CiliumEnvoyConfig (CEC) | Zero additional pods, uses existing Envoy DaemonSet, unified config | Cilium v1.18 classifies all CEC `spec.services` listeners as east/west in BPF; external traffic has no Cilium pod identity, causing `l7policy` filter to reject with HTTP 500 |
| Standalone Envoy Deployment | Full control over listener config, no BPF classification issues, supports file-based cert rotation | Extra Deployment (2 pods), separate config management |
| Gateway API with `tls.mode: Mutual` | Native Kubernetes API, no custom config | Gateway API spec does not support `tls.mode: Mutual`; not implementable |

## Decision

Standalone Envoy Deployment (2 replicas) behind a dedicated LoadBalancer Service (`cilium-gateway-gw-extapi`). Envoy is configured with downstream mTLS verification (require client certificate, validate against DFSP CA bundle) and routes verified traffic to the FSPIOP API backend services.

The root cause of the CEC failure: Cilium v1.18's BPF data plane classifies all traffic arriving at CEC `spec.services` listeners as east/west (inter-pod). External traffic from DFSPs has no Cilium security identity, so the `l7policy` BPF filter drops it with HTTP 500 before Envoy can process it. This is a fundamental architectural constraint in Cilium's current CEC implementation, not a configuration issue.

Certificate management uses volume mounts with Envoy's `watched_directory` SDS, enabling cert rotation without Envoy restart.

## Consequences

- **Extra Deployment.** 2 Envoy pods per Hub, adding ~200Mi RAM overhead.
- **File-based cert management.** DFSP CA bundles and hub server certificates are mounted as volumes. Envoy's `watched_directory` detects changes and reloads without restart.
- **Clear security boundary.** The extapi LoadBalancer exclusively handles mTLS-verified DFSP traffic, isolated from internal (gw-int) and non-mTLS external (gw-ext) traffic.
- **Outbound mTLS unaffected.** CEC continues to handle outbound mTLS origination (hub-to-DFSP callbacks) because the east/west BPF path is correct for pod-originated traffic.
- **Third LoadBalancer IP required.** See ADR-008 for the three-LB architecture this creates.
