# Prerequisites

[doc](../../index.md) / [participant](../index.md) / [integrate](../index.md) / Prerequisites

**Audiences:** participant (operator)

What the participant needs before connecting — from the Hub operator, and on its own side.

- [From the Hub operator](#from-the-hub-operator)
- [What the participant generates](#what-the-participant-generates)
- [Participant infrastructure](#participant-infrastructure)
- [The participant's FQDN](#the-participants-fqdn)

## From the Hub operator

The Hub operator creates the participant in the Hub and hands over these values out of band. They are the same for every participant of that Hub.

| Value | Example | What it is |
|-------|---------|-----------|
| `MCM_SERVER_ENDPOINT` | `https://mcm.ext.<hub-domain>/pm4mlapi` | The Connection Manager API the participant enrols against |
| `HUB_IAM_PROVIDER_URL` | `https://hydra.ext.<hub-domain>` | The OAuth2 token endpoint |
| `HUB_EXTAPI_FQDN` | `extapi.<hub-domain>` | Where the participant sends FSPIOP traffic — mTLS, always port 443 |
| The participant ID | `dfsp-201` | The participant's identifier in the scheme; also the OAuth2 `client_id` |
| Currency | ISO 4217 code | Must match a currency the Hub supports |

Without these values, contact the Hub operator before going further.

## What the participant generates

The **OAuth2 client secret is never handed over** — the participant creates it. After the Hub operator creates the participant, an activation email arrives; activate the account, log in, and generate the client credentials. The Hub never sees the secret.

That step, and the account it activates, are reached through the Hub's external endpoints — the same `mcm.ext` / `hydra.ext` hosts above. Keep the secret safe once generated; it is shown once.

The full sequence is in [the choreography](../../architecture/participant-integration.md#the-choreography).

## Participant infrastructure

The participant runs the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit) as a Docker Compose stack — its [Architecture](https://github.com/mojaloop/integration-toolkit/blob/main/doc/architecture.md) page explains what the stack contains and why. The participant needs:

| Requirement | Notes |
|-------------|-------|
| A host with Docker Engine + Compose v2 | Linux VM or equivalent |
| A **stable public address** | The FQDN must keep resolving to an address where inbound `:443` is reachable; a static IP is the simplest way to guarantee that |
| Inbound `:443` reachable from the Hub | The SDK terminates mTLS in-process on 443 |
| Outbound `:443` to the Hub | To `mcm.ext`, `hydra.ext`, and `extapi` |
| `git`, `openssl` | Cloning ITK and generating bootstrap certificates |

Verify the Hub is reachable before starting:

```bash
curl -sI https://mcm.ext.<hub-domain>/pm4mlapi
```

## The participant's FQDN

The participant chooses a fully-qualified domain name and publishes it in the participant's **own** DNS zone. The Hub uses it as the participant's callback address; it never manages DNS on the participant's behalf.

- It must resolve **publicly**, before enrolment — the Hub pins it by name and enrolment fails if it does not resolve.
- It must point at the address where the participant's inbound `:443` is reachable, and keep resolving there.
- In production this is the participant's own domain (`dfsp.examplebank.com`); the Hub never touches it.

Confirm resolution before continuing:

```bash
dig +short <participant-fqdn>
```

Next: [Connect](connect.md).
