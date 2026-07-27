# Known Issues — Participant

[doc](../../index.md) / [participant](../index.md) / [operate](../index.md) / Known issues

**Audiences:** participant (operator)

Recurring issues on the participant side, and which of them are actually the Hub operator's to fix.

## The enrolment agent submits its CSR and then stops

**Not a fault.** The agent generates and submits the CSR, then waits for the Hub operator to sign it. It resumes on its own once they do. If it stays there, the Hub operator has not signed yet — confirm with them rather than restarting anything. Restarting only re-submits and waits again.

## The SDK will not start — missing certificate files

The SDK checks for certificate files at start-up and exits if they are absent. On first bring-up, generate the throwaway bootstrap certificates before starting the stack:

```bash
../scripts/gen-bootstrap-certs.sh ./secrets
```

These are placeholders; the agent replaces them with real, Hub-signed material after enrolment. See the toolkit's [Integration guide → bootstrap certificates](https://github.com/mojaloop/integration-toolkit/blob/main/doc/integration.md#3-generate-bootstrap-certificates).

## Party lookup fails — oracle not found

A party lookup that fails with an oracle error is almost always the **Hub's** setup, not the participant's: the scheme's oracle for that identifier type was never registered. Raise it with the Hub operator — the fix is on their side. See [Hub configuration](../../adopter/deploy/hub.md#configure-the-hub).

## A transfer fails with a signature error, but quotes succeed

This specific pattern — quotes validate, transfers do not — is a **Hub-side message-signing issue**, not a problem with the participant's enrolment or certificates. Report it to the Hub operator with the transfer details; there is nothing to fix on the participant's side. Background: [JWS signing → When validation fails](../../architecture/jws-signing.md#a-different-failure-that-looks-the-same).

## The Hub cannot reach the participant — callbacks time out

The Hub connects to the participant's registered FQDN on port 443. If callbacks are timing out while outbound transfers work:

- Confirm the FQDN still resolves publicly to the current IP: `dig +short <participant-fqdn>`
- Confirm inbound 443 is open from the Hub's egress address
- If the IP changed, that is the cause — update DNS; a static IP (or automation that keeps the record current) prevents recurrence

If the participant's firewall allow-lists the Hub, note that Hub callbacks may arrive from a **different** address than the endpoint the participant connects to. Allow-listing only that endpoint can silently drop callbacks — confirm both addresses with the Hub operator. See [Running → the participant's FQDN and IP](running.md#the-participants-fqdn-and-ip).
