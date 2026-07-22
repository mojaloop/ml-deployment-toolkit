# Participant Guide

[doc](../index.md) / Participant

**Audiences:** participant (operator)

You are a **participant** — a bank, mobile money operator, or payment service provider — connecting to an existing Mojaloop Hub. This guide takes you from the details the Hub operator gives you to a live, transacting connection, and keeps it running.

You are **not** setting up a Hub. That is the [Adopter guide](../adopter/index.md), and the Hub operator is a separate organisation. You run your own stack on your own infrastructure; they never touch your cluster and you never touch theirs.

## Two journeys

| Journey | You are here when | Start |
|---------|-------------------|-------|
| **[Integrate](integrate/prerequisites.md)** | Connecting for the first time | [Prerequisites](integrate/prerequisites.md) |
| **[Operate](operate/running.md)** | Keeping the connection healthy | [Running](operate/running.md) |

## What you run

Your side is the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit) (ITK) — a Docker Compose stack that provides everything needed to exchange FSPIOP traffic:

- An **enrolment agent** that handles certificate enrolment and renewal against the Hub
- A per-participant **Vault** holding your private keys
- The **SDK scheme adapter**, which speaks FSPIOP and terminates mTLS
- A **Redis** cache for the adapter
- A **simulator** backend — a stand-in for your core banking system, which you replace when ready

Everything runs on your infrastructure. See [Participant integration architecture](../architecture/participant-integration.md) for how these pieces fit with the Hub.

## Integrate

| Page | Covers |
|------|--------|
| [Prerequisites](integrate/prerequisites.md) | What you need from the Hub operator, and on your own side |
| [Connect](integrate/connect.md) | Configure ITK, enrol, and bring the connection live |
| [Verify](integrate/verify.md) | Confirm the connection end to end |

## Operate

| Page | Covers |
|------|--------|
| [Running](operate/running.md) | Day-to-day: certificate renewal, health, swapping in your core system |
| [Known issues](operate/known-issues.md) | Recurring issues and workarounds |

## The shape of onboarding

Onboarding is a two-party exchange with the Hub operator — you each act on infrastructure the other cannot see. Before starting, read the full sequence once: **[the choreography](../architecture/participant-integration.md#the-choreography)**. Your steps are the ones marked *You*.

It is worth knowing the shape up front — that you generate your own credentials (the Hub never holds them), and that a live mTLS connection is not the finish line: the Hub operator must both sign your certificate and trigger your onboarding into the ledger before any transfer can settle. The [Connect](integrate/connect.md) and [Verify](integrate/verify.md) pages walk your side of it.
