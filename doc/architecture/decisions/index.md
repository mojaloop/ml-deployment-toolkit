# Decision Records

[doc](../../index.md) / [architecture](../index.md) / Decisions

**Audiences:** architect, platform developer, system integrator

Why non-obvious design choices were made, what else was weighed, and what each one costs.

Records are **append-only**. A decision the system has moved past is marked superseded and points at its replacement — it is never deleted, because the reasoning stays useful even when the conclusion changes. This is the one place in `doc/` that describes things which are no longer true, and superseded records say so at the top.

## Records

| # | Decision | Status |
|---|----------|--------|
| [001](001-oci-over-git.md) | OCI artifacts over Git for GitOps delivery | accepted |
| [002](002-cilium-over-istio.md) | Cilium over Istio for networking | accepted |
| [003](003-thanos-over-mimir.md) | Thanos over Mimir for long-term metrics | accepted |
| [004](004-standalone-envoy-inbound-mtls.md) | Standalone Envoy for inbound mTLS | accepted |
| [005](005-flux-over-argocd.md) | Flux over ArgoCD | accepted |
| [006](006-talos-for-onprem.md) | Talos Linux for self-managed clusters | accepted |
| [007](007-single-oci-artifact.md) | One artifact rather than one per layer | accepted |
| [008](008-three-lb-architecture.md) | Separate load balancers per traffic class | **superseded by 018** |
| [009](009-single-mysql-cluster.md) | One MySQL cluster for all services | accepted |
| [010](010-dual-realm-keycloak.md) | Dual-realm Keycloak with Kratos OIDC | **superseded by 014** |
| [011](011-dns01-over-http01.md) | DNS-01 over HTTP-01 ACME challenges | accepted · amended by 016 |
| [012](012-tps-sizing-profiles.md) | TPS-based sizing profiles | **superseded by 015** |
| [013](013-cilium-wireguard-internal-encryption.md) | WireGuard encryption for pod-to-pod traffic | accepted |
| [014](014-ory-identity-stack.md) | Ory as the complete identity and access stack | accepted |
| [015](015-two-stack-capability-config.md) | Two Terraform stacks and a capability-bound config model | accepted · amended by 016/017 |
| [016](016-generic-acme-ca.md) | Certificate authority as configuration, not a provider enum | accepted · amended by 017 |
| [017](017-explicit-capability-endpoints.md) | Capability endpoints stated, not derived | accepted |
| [018](018-per-gateway-lb-pools.md) | Per-gateway LB-IPAM pools with selector labels | accepted |
| [019](019-health-gated-reconciliation.md) | Health-gated reconciliation ordering | accepted |
| [020](020-vault-kv-v1.md) | Vault KV engine version 1 | accepted |
| [021](021-scoped-callback-egress.md) | Callback egress policy scoped to the calling services | accepted |
| [022](022-helm-values-layering.md) | Helm values layered through valuesFrom, never inline | accepted |
| [023](023-tail-based-trace-sampling.md) | Tail-based trace sampling | accepted |
| [024](024-narrow-provider-boundary.md) | The provider boundary is a kubeconfig | accepted |

## Writing a new record

Number sequentially. Use the format in [DOCUMENTATION.md](../../DOCUMENTATION.md#decision-tracing): context, alternatives considered, decision, consequences.

Two things separate a useful record from a rubber stamp:

**Alternatives must be real.** If the table lists only options nobody seriously considered, it documents nothing. Record what was genuinely in contention and why it lost.

**Consequences must include the costs.** A record listing only benefits is marketing. State what the decision rules out, what it makes harder, and what future maintainers will find surprising — that is the part a reader needs three years from now.

Reference records by number from other documents, so the claim and its reasoning travel together:

```markdown
Metrics use Thanos ([ADR-003](003-thanos-over-mimir.md)).
```
