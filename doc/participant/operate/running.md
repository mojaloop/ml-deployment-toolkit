# Running

[doc](../../index.md) / [participant](../index.md) / [operate](../index.md) / Running

**Audiences:** participant (operator)

Keeping a connected participant healthy — certificates, health, and swapping the simulator for the real core system.

- [Certificate renewal](#certificate-renewal)
- [Health](#health)
- [Replacing the simulator](#replacing-the-simulator)
- [The participant's FQDN and IP](#the-participants-fqdn-and-ip)

## Certificate renewal

The enrolment agent handles renewal against the Hub. The client certificate is long-lived, so renewal is infrequent — but the agent, not the participant, drives it, and the SDK takes new certificates over its control channel without a restart.

The participant does **not** manage certificate files by hand. If the agent is running, renewal is handled. What the participant does need to keep alive is the agent itself — if it is down, an expiring certificate will not renew.

One thing to know about the Hub's own certificate: the Hub's FSPIOP endpoint presents a certificate signed by the **scheme CA, not a public authority**. The SDK trusts it because enrolment delivered the Hub CA. A certificate-trust failure toward the Hub therefore points at the Hub CA in the participant's trust store, not at a public-certificate problem. See [certificate authorities](../../architecture/security.md#certificate-authorities).

## Health

```bash
docker compose ps                 # all services up
docker compose logs -f mcm-agent  # enrolment and renewal activity
docker compose logs -f <sdk>      # FSPIOP traffic
```

The agent's log is where enrolment state, renewal, and any Hub-side rejection surface. The SDK's log is where message-level problems — signing, validation, connectivity — appear.

Each side operates blind to the other's internals. If the Hub operator cannot reach the participant, the coordination channel is human — there is no shared dashboard.

## Replacing the simulator

The bundled simulator stands in for a core banking system. To go live with a real one, point the SDK's backend at the participant's connector instead:

```bash
BACKEND_ENDPOINT=<connector-service>
```

The connector must implement the Mojaloop SDK backend API over plain HTTP (it is an internal, pod-to-pod interface — no TLS, no auth) and be reachable from the SDK. The API is documented in the SDK scheme adapter project. Start the stack without the simulator profile once the real backend is in place.

Swapping the backend changes nothing about enrolment or mTLS — that boundary is between the SDK and the Hub, and is independent of what sits behind the SDK.

## The participant's FQDN and IP

The Hub reaches the participant at the registered FQDN, on port 443, over mTLS. Two things must stay stable for that to keep working:

- **The FQDN must keep resolving to the participant.** The Hub resolves the FQDN and connects. If the host's address changes and DNS does not follow immediately, the Hub cannot reach the participant and callbacks fail — keep the record accurate. A static IP makes this trivial; anything that keeps DNS current also works.
- **The FQDN must keep resolving publicly.** Changing it is a re-registration with the Hub operator, not a silent DNS edit — the FQDN is part of what the Hub has on record for the participant.

If the Hub operator handed over a single Hub address to allow-list, note that inbound (to the Hub) and callbacks (from the Hub) may currently arrive from different Hub addresses — confirm both with the operator when setting up the firewall, so it does not silently drop callbacks.
