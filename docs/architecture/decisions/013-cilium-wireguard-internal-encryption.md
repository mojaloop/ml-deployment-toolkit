# 013 — Cilium WireGuard for internal traffic encryption

[docs](../../index.md) / [architecture](../index.md) / [decisions](./) / 013 — Cilium WireGuard for internal traffic encryption

**Date:** 2026-07-10
**Status:** accepted
**Audiences:** architect, platform engineer

## Context

East-west traffic inside an environment cluster — Kafka produce/fetch, MySQL,
Redis, MongoDB, and inter-service FSPIOP calls — crosses nodes in plaintext.
mTLS exists only at the edges (inbound standalone Envoy per ADR-004, outbound
via CiliumEnvoyConfig per ADR-002). Anyone able to observe the network between
nodes sees transfer payloads and credentials on the wire.

Mojaloop's traffic profile is L4-dominated: the switch is Kafka-choreographed,
so most cross-node bytes are raw TCP, not HTTP. Message authenticity is
already provided end-to-end at the application layer (JWS on FSPIOP), and
counterparty identity by the DFSP mTLS gateways — the missing property is
confidentiality on the internal wire, not another identity layer.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| **Cilium WireGuard** (chosen) | In-kernel, per-node keys generated at runtime, zero new pods, one Helm value, integrates with the existing eBPF datapath | Per-packet CPU cost; double encapsulation in vxlan tunnel mode; node-level (no workload identity) |
| Talos KubeSpan | Host-level WireGuard covering all node traffic; built into Talos | Designed for multi-site node meshes; documented conflicts with advanced Cilium configs (kube-proxy replacement, BPF masquerade, native routing) — Sidero docs recommend Cilium WireGuard instead when advanced Cilium features are in use |
| Istio Ambient (ztunnel) on Cilium | Workload identity (SPIFFE), cheap L7 mTLS | Re-introduces the two-data-plane setup removed by ADR-002; userspace hop per cross-node packet on both nodes (costly for Kafka/DB bytes); requires socket-LB workarounds with kube-proxy replacement; untested interaction with CEC-based mTLS |
| Cilium mutual auth (SPIRE) | Workload identity within Cilium | Beta; new SPIRE StatefulSet; first-packet drops during identity handshake; provides no payload encryption by itself |

## Decision

Enable Cilium's WireGuard transparent encryption for all clusters:

```yaml
encryption:
  enabled: true
  type: wireguard
```

- Set in `gitops/talos/cilium/helmrelease.yaml` (Flux-managed runtime config)
  **and** `rendering/cilium/values.yaml` (Talos bootstrap manifest), so a
  freshly built cluster never runs a plaintext window before Flux takeover
  (see ADR-006 for the two-phase mechanism).
- WireGuard keys are generated per-node by the cilium-agent at runtime —
  nothing is rendered into the committed bootstrap manifest.
- `encryption.nodeEncryption` stays off: host-originated traffic (kubelet →
  API server, Talos apid/trustd) is already TLS/mTLS-protected by Kubernetes
  and Talos respectively.
- Workload identity (SPIRE mutual auth or a mesh) is explicitly deferred
  until a requirement for per-workload authorization exists.

## Consequences

- **Cross-node pod traffic is ciphertext on the wire** (WireGuard, UDP/51871).
  Same-node pod traffic never leaves the host and is unaffected.
- **Not authorization.** Any pod can still reach any other pod; segmentation
  is a separate layer (CiliumNetworkPolicies).
- **MTU shrinks** (~130 B combined vxlan + WireGuard overhead). New endpoints
  pick it up automatically; long-lived pods keep the old MTU until restarted —
  plan a rolling restart after enablement on live clusters.
- **Double encapsulation in tunnel mode.** Pod traffic is encapsulated by
  vxlan, then encrypted by WireGuard — a per-packet CPU cost on all cross-node
  traffic. Measured under the k6 performance workstream, not gated here.
- **Verification is mandatory, not assumed.** Historical Cilium advisories
  (e.g. GHSA-v6q2-4qr3-5cw6, fixed well before 1.19) leaked L7-proxied traffic
  despite encryption being "on". After enablement, confirm with
  `cilium-dbg encrypt status` (all peers listed) and tcpdump ciphertext checks
  on both a plain L4 flow (Kafka) and an Envoy/CEC-proxied flow.
- **Rollout is gradual, not atomic.** Agents roll node by node; node pairs
  fall back to plaintext until both peers have exchanged keys. Reverting the
  value rolls back to plaintext with no persistent state.
- **KubeSpan must stay disabled** on all Talos environments — running both
  WireGuard layers double-encrypts and conflicts with the Cilium datapath.
