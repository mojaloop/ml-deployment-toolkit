# Participant

[doc](../index.md) / Participant

**Audiences:** participant

**The participant journey is documented in the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit).** A connecting institution — a bank, mobile money operator, or payment service provider — reads that documentation from prerequisites through enrolment, verification, and day-2 operation, and needs nothing from this repository to do its part.

This repository keeps the Hub side of the relationship:

- **[The integration contract](../architecture/participant-integration.md)** — the onboarding choreography, what the Hub hands the participant, what the participant returns, and the protocol semantics both sides implement. The Integration Toolkit's guides mirror the parts a participant needs day-to-day and cite the contract as canonical.
- **[Onboarding participants](../adopter/operate/onboarding-participants.md)** — the Hub operator's half of the choreography.

A participant escalating an issue the Integration Toolkit's documentation attributes to the Hub — an unregistered oracle, a callback that never arrives, a certificate signature still pending — brings it to the Hub operator, who starts from those two pages.
