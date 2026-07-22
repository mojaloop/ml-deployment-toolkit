# Connect

[doc](../../index.md) / [participant](../index.md) / [integrate](../index.md) / Connect

**Audiences:** participant (operator)

Configure the Integration Toolkit, enrol with the Hub, and bring the connection live. The ITK's own deployment details are in the [Integration Toolkit repository](https://github.com/mojaloop/integration-toolkit); this page is the flow and the values that matter at the boundary with the Hub.

> The Integration Toolkit currently tracks the `feat/mcm-agent` branch. Pin to it until it merges.

- [1. Activate and get your credentials](#1-activate-and-get-your-credentials)
- [2. Publish your DNS record](#2-publish-your-dns-record)
- [3. Get and configure ITK](#3-get-and-configure-itk)
- [4. Generate bootstrap certificates](#4-generate-bootstrap-certificates)
- [5. Start the stack](#5-start-the-stack)
- [6. Enrol](#6-enrol)

## 1. Activate and get your credentials

When the Hub operator creates your participant, you receive an activation email. Open it, activate your account, set a password, then log in and **generate your own OAuth2 client credentials**. Copy the client secret — it is shown once, and it becomes `AUTH_CLIENT_SECRET` below.

The Hub operator cannot do this for you and never sees the secret. See [why](../../architecture/security.md#authorization-model).

## 2. Publish your DNS record

Point your chosen FQDN at your host's static IP, in your own DNS zone:

```bash
dig +short <your-fqdn>     # must return your static IP before enrolling
```

Enrolment registers this FQDN with the Hub as your callback address, and the Hub pins it by name — if it does not resolve, enrolment fails.

## 3. Get and configure ITK

Clone the toolkit and switch to the tracked branch:

```bash
git clone https://github.com/mojaloop/integration-toolkit.git
cd integration-toolkit
git switch feat/mcm-agent
cd docker
cp .env.sample .env
```

Fill in `.env`. The values that cross the boundary with the Hub:

```bash
# Your identity
DFSP_ID=<your-participant-id>
DFSP_FQDN=<your-fqdn>
DFSP_CURRENCIES=<currency>

# Hub endpoints — from the Hub operator
MCM_SERVER_ENDPOINT=https://mcm.ext.<hub-domain>/pm4mlapi
HUB_IAM_PROVIDER_URL=https://hydra.ext.<hub-domain>
HUB_EXTAPI_FQDN=extapi.<hub-domain>

# Your credentials — the secret you generated in step 1
AUTH_CLIENT_ID=<your-participant-id>
AUTH_CLIENT_SECRET=<the-secret-you-copied>

# Backend — the bundled simulator to start; your core system later
BACKEND_ENDPOINT=sim-backend:3000
```

Keep `.env` at `chmod 600` — it holds your client secret. The remaining ITK settings — host ports, log level, optional observability endpoints — are documented in the toolkit repo.

If the Hub operator gave you observability endpoints and you want to ship telemetry to their Tooling Cluster, set those too; otherwise omit them.

## 4. Generate bootstrap certificates

The SDK will not start without certificate files present, so ITK ships a helper that creates throwaway self-signed ones:

```bash
../scripts/gen-bootstrap-certs.sh ./secrets
```

These are placeholders only. They satisfy the SDK's start-up file checks; the enrolment agent replaces the live TLS material and signing keys at runtime once you enrol — the SDK picks up the real certificates over its control channel without a restart. See [how the SDK receives certificates](../../architecture/participant-mtls.md#end-to-end-lifecycle).

## 5. Start the stack

```bash
docker compose --profile test up -d
docker compose ps
```

The `test` profile starts the bundled simulator as a stand-in core system. Add other profiles (for example, observability) as documented in the toolkit repo.

## 6. Enrol

Watch the enrolment agent:

```bash
docker compose exec mcm-agent mcm-agent
```

It generates a certificate signing request, submits it to the Hub, and then **stops and waits** — the certificate is pending the Hub operator's signature. This pause is expected. Leave it open.

At this point the ball is in the Hub operator's court: they sign your CSR and trigger your onboarding. Once they do, the agent advances on its own and reports **fully synced** — the moment your mTLS connection goes live. No container restart is needed; the SDK takes the live certificates over the control channel.

If it never advances, the Hub operator has not yet signed — that is a coordination step, not a fault on your side. Confirm with them before troubleshooting.

Next: [Verify](verify.md).
