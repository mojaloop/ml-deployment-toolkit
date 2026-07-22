# Running

[doc](../../index.md) / [participant](../index.md) / [operate](../index.md) / Running

**Audiences:** participant (operator)

Keeping a connected participant healthy — certificates, health, and swapping the simulator for your real core system.

- [Certificate renewal](#certificate-renewal)
- [Health](#health)
- [Replacing the simulator](#replacing-the-simulator)
- [Your FQDN and IP](#your-fqdn-and-ip)

## Certificate renewal

Your enrolment agent handles renewal against the Hub. Your client certificate is long-lived, so renewal is infrequent — but the agent, not you, drives it, and the SDK takes new certificates over its control channel without a restart.

You do **not** manage certificate files by hand. If the agent is running, renewal is handled. What you do need to keep alive is the agent itself — if it is down, an expiring certificate will not renew.

One thing to know about the Hub's own certificate: the Hub's FSPIOP endpoint presents a certificate signed by the **scheme CA, not a public authority**. Your SDK trusts it because enrolment gave you the Hub CA. If you ever see a certificate-trust failure toward the Hub, it points at the Hub CA in your trust store, not at a public-certificate problem. See [certificate authorities](../../architecture/security.md#certificate-authorities).

## Health

```bash
docker compose ps                 # all services up
docker compose logs -f mcm-agent  # enrolment and renewal activity
docker compose logs -f <sdk>      # FSPIOP traffic
```

The agent's log is where enrolment state, renewal, and any Hub-side rejection surface. The SDK's log is where message-level problems — signing, validation, connectivity — appear.

If you configured observability endpoints, your metrics, logs, and traces are visible in the Hub operator's Grafana. That is the only shared visibility between the two sides; otherwise each operates blind to the other's internals.

## Replacing the simulator

The bundled simulator stands in for a core banking system. To go live with your own, point the SDK's backend at your connector instead:

```bash
BACKEND_ENDPOINT=<your-connector-service>
```

Your connector must implement the Mojaloop SDK backend API over plain HTTP (it is an internal, pod-to-pod interface — no TLS, no auth) and be reachable from the SDK. The API is documented in the SDK scheme adapter project. Start the stack without the simulator profile once your backend is in place.

Nothing about enrolment or mTLS changes when you swap the backend — that boundary is between your SDK and the Hub, and is independent of what sits behind your SDK.

## Your FQDN and IP

The Hub reaches you at the FQDN you registered, on port 443, over mTLS. Two things must stay stable for that to keep working:

- **Your IP must not change.** The Hub resolves your FQDN and connects. If your host's address changes and DNS does not follow immediately, the Hub cannot reach you and callbacks fail. This is why a static IP is a prerequisite.
- **Your FQDN must keep resolving publicly.** If you need to change it, treat it as a re-registration with the Hub operator, not a silent DNS edit — the FQDN is part of what they have on record for you.

If the Hub gave you a single Hub address to allow-list, note that inbound (to the Hub) and callbacks (from the Hub) may currently arrive from different Hub addresses — confirm both with the operator when setting up your firewall, so you do not silently drop callbacks.
