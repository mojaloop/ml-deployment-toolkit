# Prerequisites

[doc](../../index.md) / [participant](../index.md) / [integrate](../index.md) / Prerequisites

**Audiences:** participant (operator)

What you need before connecting — from the Hub operator, and on your own side.

- [From the Hub operator](#from-the-hub-operator)
- [What you generate yourself](#what-you-generate-yourself)
- [Your infrastructure](#your-infrastructure)
- [Your FQDN](#your-fqdn)

## From the Hub operator

The Hub operator creates your participant in their system and hands you these out of band. They are the same for every participant of that Hub.

| Value | Example | What it is |
|-------|---------|-----------|
| `MCM_SERVER_ENDPOINT` | `https://mcm.ext.<hub-domain>/pm4mlapi` | The Connection Manager API you enrol against |
| `HUB_IAM_PROVIDER_URL` | `https://hydra.ext.<hub-domain>` | The OAuth2 token endpoint |
| `HUB_EXTAPI_FQDN` | `extapi.<hub-domain>` | Where you send FSPIOP traffic — mTLS, always port 443 |
| Your participant ID | `dfsp-201` | Your identifier in the scheme; also your OAuth2 `client_id` |
| Currency | ISO 4217 code | Must match a currency the Hub supports |

If you do not have these, contact the Hub operator before going further.

## What you generate yourself

Your **OAuth2 client secret is not handed to you** — you create it. After the Hub operator creates your participant, you receive an activation email, activate your account, log in, and generate your own credentials. The Hub never sees the secret.

That step, and the account it activates, are reached through the Hub's external endpoints — the same `mcm.ext` / `hydra.ext` hosts above. Keep the secret safe once generated; it is shown once.

The full sequence is in [the choreography](../../architecture/participant-integration.md#the-choreography).

## Your infrastructure

You run the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit) as a Docker Compose stack. You need:

| Requirement | Notes |
|-------------|-------|
| A host with Docker Engine + Compose v2 | Linux VM or equivalent |
| A **static IP** | The Hub dials your FQDN directly; a changing address breaks inbound mTLS |
| Inbound `:443` reachable from the Hub | The SDK terminates mTLS in-process on 443 |
| Outbound `:443` to the Hub | To `mcm.ext`, `hydra.ext`, and `extapi` |
| `git`, `openssl` | Cloning ITK and generating bootstrap certificates |

Verify you can reach the Hub before starting:

```bash
curl -sI https://mcm.ext.<hub-domain>/pm4mlapi
```

## Your FQDN

You choose a fully-qualified domain name for your participant and publish it in **your own** DNS zone. The Hub uses it as your callback address; it never manages DNS on your behalf.

- It must resolve **publicly**, before you enrol — the Hub pins it by name and enrolment fails if it does not resolve.
- It must point at your static IP.
- In production this is your own domain (`dfsp.yourbank.com`); the Hub never touches it.

Confirm resolution before continuing:

```bash
dig +short <your-fqdn>
```

Next: [Connect](connect.md).
