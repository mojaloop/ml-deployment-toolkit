# Connect

[doc](../../index.md) / [participant](../index.md) / [integrate](../index.md) / Connect

**Audiences:** participant (operator)

Configure the Integration Toolkit, enrol with the Hub, and bring the connection live. The ITK's own deployment mechanics are owned by the toolkit's [Integration guide](https://github.com/mojaloop/integration-toolkit/blob/main/doc/integration.md); this page is the flow and the values that matter at the boundary with the Hub.

- [1. Activate and get credentials](#1-activate-and-get-credentials)
- [2. Publish the DNS record](#2-publish-the-dns-record)
- [3. Deploy the Integration Toolkit](#3-deploy-the-integration-toolkit)
- [4. Enrol](#4-enrol)

## 1. Activate and get credentials

When the Hub operator creates the participant, an activation email arrives. Open it, activate the account, set a password, then log in and **generate the participant's own OAuth2 client credentials**. Copy the client secret — it is shown once, and it becomes `AUTH_CLIENT_SECRET` below.

The Hub operator cannot do this step and never sees the secret. See [why](../../architecture/security.md#authorization-model).

## 2. Publish the DNS record

Point the chosen FQDN, in the participant's own DNS zone, at the address where the stack's inbound `:443` will be reachable:

```bash
dig +short <participant-fqdn>     # must resolve before enrolling
```

Enrolment registers this FQDN with the Hub as the participant's callback address, and the Hub pins it by name — if it does not resolve, enrolment fails.

## 3. Deploy the Integration Toolkit

```bash
git clone https://github.com/mojaloop/integration-toolkit.git
cd integration-toolkit
```

Follow the toolkit's [Integration guide](https://github.com/mojaloop/integration-toolkit/blob/main/doc/integration.md) to fill in `.env`, generate the bootstrap certificates, and start the stack. Its value table covers every variable — the five values from [Prerequisites](prerequisites.md#from-the-hub-operator) plus the credentials from step 1 are all of the Hub-side input. Keep `.env` at `chmod 600` — it holds the client secret.

The bootstrap certificates that guide generates are placeholders only. They satisfy the SDK's start-up file checks; the enrolment agent replaces the live TLS material and signing keys at runtime once the participant enrols — the SDK picks up the real certificates over its control channel without a restart. See [how the SDK receives certificates](../../architecture/participant-mtls.md#end-to-end-lifecycle).

## 4. Enrol

Watch the enrolment agent:

```bash
docker compose exec mcm-agent mcm-agent
```

It generates a certificate signing request, submits it to the Hub, and then **stops and waits** — the certificate is pending the Hub operator's signature. This pause is expected. Leave it open.

At this point the ball is in the Hub operator's court: they sign the CSR and trigger onboarding. Once they do, the agent advances on its own and reports **fully synced** — the moment the mTLS connection goes live. No container restart is needed; the SDK takes the live certificates over the control channel.

If it never advances, the Hub operator has not yet signed — that is a coordination step, not a fault on the participant's side. Confirm with them before troubleshooting.

Next: [Verify](verify.md).
