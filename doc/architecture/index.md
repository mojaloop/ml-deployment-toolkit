# Architecture

[doc](../index.md) / Architecture

**Audiences:** all

What the system is and how it works, stated once. Every other guide references these pages rather than restating them. The *why* behind each non-obvious choice lives in [decision records](decisions/index.md); these pages cite them by number.

## Where to start

**New to the toolkit?** Read [System overview](system-overview.md). It covers the delivery chain, cluster roles, reconciliation order, and the configuration system, and is the prerequisite for everything else. For the full configuration model — the layer composition, the no-knobs rule, and the decisions behind them — continue with the [config-layering design](config-layering-design.md).

## How these fit together

```mermaid
flowchart TD
    ov["System overview"]
    cld["Config-layering design"]
    pm["Provider model"]
    gs["GitOps structure"]
    nw["Networking"]
    sec["Security"]
    dl["Data layer"]
    obs["Observability"]
    pi["Participant integration"]
    pm2["Participant mTLS"]

    ov --> cld
    ov --> pm
    ov --> gs
    ov --> nw
    ov --> sec
    ov --> dl
    ov --> obs
    nw --> pi
    sec --> pi
    pi --> pm2
    pi --> jws["JWS signing"]
```

## Documents

| Document | Covers |
|----------|--------|
| [System overview](system-overview.md) | Delivery chain, cluster roles, reconciliation order, configuration tiers |
| [Config-layering design](config-layering-design.md) | The configuration model as designed and confirmed — layers, parameterization, no-knobs templates, placement contract |
| [Provider model](provider-model.md) | Infrastructure and DNS providers, what is supported, deployment templates |
| [GitOps structure](gitops-structure.md) | OCI artifact layout, Flux consumption, substitution, versioning |
| [Networking](networking.md) | Four entry points, gateways, load balancer addresses, DNS, certificates |
| [Security](security.md) | Secret isolation, Ory identity, authorization model, encryption, hardening |
| [Data layer](data-layer.md) | The four stores, data modes, backup and PITR coverage, what is not recoverable |
| [Observability](observability.md) | Metrics, logs, tracing, dashboards, alerting, retention |
| [Participant integration](participant-integration.md) | The integration contract — onboarding choreography and both interface tables |
| [Participant mTLS](participant-mtls.md) | Scheme PKI, certificate lifecycle across components, rotation, planned edge controls |
| [JWS message signing](jws-signing.md) | Message-level signing, Hub key distribution and rotation |

## Decision records

Non-obvious design choices are recorded in [decisions](decisions/index.md). Each captures the context, the alternatives weighed, and the consequences.

Records are **append-only**. A decision the system has moved past is marked superseded and points at its replacement — it is never deleted, because the reasoning stays useful even when the conclusion changes.

## Reading these against a running system

Two things in these pages are stated as **target** rather than current behaviour, each marked where it appears: participants reach MCM and Kratos self-service through `gw-ext` ([Networking](networking.md#gw-ext--external-parties)), and the planned FSPIOP edge controls ([Participant mTLS](participant-mtls.md)).

Everything else describes what the code does today.

## Looking for procedures?

This section describes. The guides instruct:

- [Adopter](../adopter/index.md) — deploy, recover, operate a Hub
- [Participant](../participant/index.md) — signpost to the Integration Toolkit documentation
- [Platform](../platform/index.md) — build and extend the distribution
- [Integrator](../integrator/index.md) — customize and republish
