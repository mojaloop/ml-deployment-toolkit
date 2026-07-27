# Onboarding Participants

[doc](../../index.md) / [adopter](../index.md) / [operate](../index.md) / Onboarding participants

**Audiences:** adopter (operate)

The Hub-side procedure for bringing a participant online. This is one half of a two-party exchange — the participant does the other half on their own infrastructure. For the full sequence and the reasoning, see [Participant integration](../../architecture/participant-integration.md#the-choreography); this page is what **the adopter**, acting as HubOps, does.

- [Who does what](#who-does-what)
- [Before starting](#before-starting)
- [1. Create the participant](#1-create-the-participant)
- [2. Hand over the endpoints](#2-hand-over-the-endpoints)
- [3. Sign the certificate](#3-sign-the-certificate)
- [4. Trigger onboarding](#4-trigger-onboarding)
- [5. Confirm](#5-confirm)
- [Blocking a participant](#blocking-a-participant)

## Who does what

Onboarding interleaves the two sides. The adopter's actions are the ones marked **Adopter**:

| # | Who | Action |
|---|-----|--------|
| 1 | **Adopter** | Create the participant in MCM |
| 2 | Participant | Activates their account, generates their own credentials |
| 3 | **Adopter** | Hand over the Hub endpoints (out of band) |
| 4 | Participant | Configures and starts their agent; it submits a CSR |
| 5 | **Adopter** | Sign the CSR |
| 6 | **Adopter** | Trigger onboarding — creates the participant in the ledger |
| 7 | Participant | Agent retrieves the certificate; the connection goes live |

The adopter cannot generate the participant's credentials for them — the authorization model prevents it by design, so step 2 is necessarily the participant's. See [Security → Authorization model](../../architecture/security.md#authorization-model).

## Before starting

- The Hub is deployed and [configured](../deploy/hub.md#configure-the-hub) — currency, ledger accounts, settlement model, and oracle exist. A participant cannot transact on a Hub with no settlement model.
- **SMTP is working.** MCM sends the participant an activation email; without SMTP, they never receive it and cannot proceed. Confirm it before creating anyone.
- Each participant needs a **distinct email address** — MCM keys account activation on it.

The adopter works in MCM at `https://mcm.int.<domain>`, using the HubOps login (`HUB_ADMIN_EMAIL` / `HUB_ADMIN_PASSWORD`).

## 1. Create the participant

In MCM:

1. **Participants → New DFSP**
2. Fill in:
   - **Name / ID** — the participant identifier, e.g. `dfsp-201`. This becomes their OAuth2 `client_id`.
   - **Currency** — must match a currency configured on the Hub
   - **Email** — the participant operator's address
3. **Create**

MCM sends an activation email to that address. The participant activates, logs in, and generates their own OAuth2 client credentials — the adopter never sees the secret.

## 2. Hand over the endpoints

Give the participant the Hub endpoints. These are the same for every participant and are the ones the adopter collected in [Deploy a Hub → Collect integration details](../deploy/hub.md#collect-integration-details):

```
MCM_SERVER_ENDPOINT=https://mcm.ext.<domain>/pm4mlapi
HUB_IAM_PROVIDER_URL=https://hydra.ext.<domain>
HUB_EXTAPI_FQDN=extapi.<domain>
DFSP_CURRENCIES=<currency>
```

These are not secret, but they are not discoverable either — the hand-off is a real step. What the participant does with them is the [Participant guide](../../participant/index.md).

## 3. Sign the certificate

Once the participant starts their agent, it submits a certificate signing request and then waits. On the Hub side, a pending CSR appears in MCM.

In MCM, find the participant, locate its pending CSR, and sign it. This issues their client certificate against the scheme CA.

The participant's agent is idle until the adopter signs — an agent that "stopped" after submitting its CSR is waiting for the Hub, not broken.

## 4. Trigger onboarding

Signing the certificate is **not** the same as onboarding. Signing issues the certificate; onboarding creates the participant *in the scheme* — its central-ledger record, net debit cap, funded settlement account, and registered endpoints.

Trigger onboarding in MCM, then watch the provisioning job:

```bash
export KUBECONFIG=$(pwd)/artifacts/<hub-env>/kubernetes/kubeconfig
kubectl -n mojaloop get jobs -w | grep onboard
kubectl -n mojaloop logs -f job/<onboard-job-name>
```

The job applies the `ONBOARDING_*` defaults from the Hub's `.env` — funds-in, net debit cap. Until it completes, the participant exists in MCM but not in the ledger, and no transfer involving it can settle.

## 5. Confirm

The participant appears in the Finance Portal (`https://finance-portal.int.<domain>`) with a position and a net debit cap, and its certificate shows signed in MCM with its endpoints registered.

The participant confirms the live connection from their side — their agent reports enrolled once it retrieves the certificate. If transfers still fail after everything looks correct here, the likely causes are message-signing rather than onboarding — see [JWS signing → When validation fails](../../architecture/jws-signing.md#when-validation-fails).

## Blocking a participant

To stop a participant transacting — suspension, default, or a suspected compromise — **disable it in the Finance Portal.** This takes effect immediately: the central ledger rejects everything from a disabled participant, regardless of its certificate.

The adopter does not touch PKI to block someone. Blocking is a scheme-membership action; the certificate lifecycle is a separate concern. See [Participant mTLS → Blocking and offboarding](../../architecture/participant-mtls.md#blocking-and-offboarding).
