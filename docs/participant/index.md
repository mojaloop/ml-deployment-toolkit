# Participant Guide

[docs](../index.md) / Participant Guide

**Audiences:** participant (DFSP operator)

You are in the right place if you are a **Digital Financial Service Provider (DFSP)** — a bank, mobile money operator, payment service provider, or similar institution — and you want to connect to an existing Mojaloop switch as a participant.

You are **not** setting up a switch. That's the [Adopter guide](../adopter/index.md). You run your own DFSP system on your own infrastructure, and the switch operator is a separate organisation.

This guide walks through deploying the [`dfsp/`](../../dfsp/) Helm chart on your own Kubernetes cluster and connecting it to the switch.

## What you deploy

A single, self-contained Helm release that provides everything needed to exchange FSPIOP traffic with the switch:

- A per-DFSP HashiCorp Vault (owns your DFSP's private CA and keys).
- The MCM agent (handles certificate enrolment and renewal against the switch).
- The Mojaloop SDK scheme adapter (speaks FSPIOP on the wire).
- A Redis cache for the SDK adapter.
- A simulator backend (a stand-in for your real core-banking system — replace this when you're ready).

Everything runs in one Kubernetes namespace on your side. The switch operator never touches your cluster and you never touch theirs.

For the full picture of how these pieces fit together and how they integrate with the switch, see [DFSP Integration architecture](../architecture/dfsp-integration.md).

## Contents

| Page | Description |
|------|-------------|
| [Prerequisites](prerequisites.md) | What you need from the switch operator, what tooling you need, what DNS and TLS you must prepare |
| [Installation](installation.md) | Install the chart, back up the recovery kit, configure DNS, verify connectivity |

## Quick start

1. **Ask the switch operator** for `MCM_SERVER_ENDPOINT`, `HUB_IAM_PROVIDER_URL`, `HUB_EXTAPI_FQDN`, your `DFSP_ID`, and your OIDC client secret. The Keycloak client id is the same as your `DFSP_ID` by convention.
2. **Decide on a DFSP FQDN** that the switch can reach on :443 from its egress network.
3. **Create a Kubernetes Secret** holding the OIDC client secret (required before install).
4. **Write a minimal `values.yaml`** with the hub endpoints plus your chosen FQDN.
5. **Install**:

   ```bash
   helm install dfsp ./dfsp -n dfsp-<your-id> -f values.yaml
   ```

6. **Point DNS** at the `sdk-inbound` LoadBalancer IP that the chart creates.
7. **Tell the switch operator** that your FQDN is live, so they can register it as your callback.

Full instructions are in [Installation](installation.md). Start from [Prerequisites](prerequisites.md) if this is your first DFSP deployment.

## What's NOT in this guide

- Anything about **installing a Mojaloop switch** — that's for the switch operator, covered in [Adopter guide](../adopter/index.md).
- **Kafka-based event handlers, bulk transfers, TTK, observability stack** — the default chart deploys a minimal FSPIOP footprint. You can add more components if needed.
- **Scheme rules, participant onboarding procedures, commercial arrangements** — those are between you and the scheme operator.

## See also

- [DFSP Integration architecture](../architecture/dfsp-integration.md) — how the DFSP stack integrates with the switch.
- [Chart README](../../dfsp/README.md) — exhaustive values reference.
