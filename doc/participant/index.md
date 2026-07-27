# Participant Guide

[doc](../index.md) / Participant

**Audiences:** participant (operator)

This guide is for a **participant** — a bank, mobile money operator, or payment service provider — connecting to an existing Mojaloop Hub. It takes the participant from the details the Hub operator hands over to a live, transacting connection, and keeps it running.

This is **not** the guide for setting up a Hub. That is the [Adopter guide](../adopter/index.md), and the Hub operator is a separate organisation. The participant runs its own stack on its own infrastructure; the Hub operator never touches the participant's cluster, and the participant never touches the Hub's.

## Two journeys

| Journey | The participant is here when | Start |
|---------|-------------------|-------|
| **[Integrate](integrate/prerequisites.md)** | Connecting for the first time | [Prerequisites](integrate/prerequisites.md) |
| **[Operate](operate/running.md)** | Keeping the connection healthy | [Running](operate/running.md) |

## What the participant runs

The participant's side is the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit) (ITK) — a Docker Compose stack that provides everything needed to exchange FSPIOP traffic:

- An **enrolment agent** that handles certificate enrolment and renewal against the Hub
- A per-participant **Vault** holding the participant's private keys
- The **SDK scheme adapter**, which speaks FSPIOP and terminates mTLS
- A **Redis** cache for the adapter
- A **simulator** backend — a stand-in for the participant's core banking system, which the participant replaces when ready

Everything runs on the participant's infrastructure. See [Participant integration architecture](../architecture/participant-integration.md) for how these pieces fit with the Hub. The toolkit documents itself: [Architecture](https://github.com/mojaloop/integration-toolkit/blob/main/doc/architecture.md) (why and what) and the [Integration guide](https://github.com/mojaloop/integration-toolkit/blob/main/doc/integration.md) (deploy and connect).

## Integrate

| Page | Covers |
|------|--------|
| [Prerequisites](integrate/prerequisites.md) | What the participant needs from the Hub operator, and on its own side |
| [Connect](integrate/connect.md) | Configure ITK, enrol, and bring the connection live |
| [Verify](integrate/verify.md) | Confirm the connection end to end |

## Operate

| Page | Covers |
|------|--------|
| [Running](operate/running.md) | Day-to-day: certificate renewal, health, swapping in the real core system |
| [Known issues](operate/known-issues.md) | Recurring issues and workarounds |

## The shape of onboarding

Onboarding is a two-party exchange with the Hub operator — each party acts on infrastructure the other cannot see. Before starting, read the full sequence once: **[the choreography](../architecture/participant-integration.md#the-choreography)**. The participant's steps are the ones marked *ParticipantOps*.

It is worth knowing the shape up front — the participant generates its own credentials (the Hub never holds them), and a live mTLS connection is not the finish line: the Hub operator must both sign the participant's certificate and trigger onboarding into the ledger before any transfer can settle. The [Connect](integrate/connect.md) and [Verify](integrate/verify.md) pages walk the participant's side of it.
