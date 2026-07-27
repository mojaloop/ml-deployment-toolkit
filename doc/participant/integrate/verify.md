# Verify

[doc](../../index.md) / [participant](../index.md) / [integrate](../index.md) / Verify

**Audiences:** participant (operator)

Confirm the connection works — from the agent state, to a party lookup, to a completed transfer.

- [The connection is live](#the-connection-is-live)
- [Register a test party](#register-a-test-party)
- [Send a test transfer](#send-a-test-transfer)
- [If a transfer fails](#if-a-transfer-fails)

## The connection is live

The enrolment agent should report **fully synced** after the Hub operator signs the CSR and triggers onboarding. Confirm the stack is healthy:

```bash
docker compose ps          # all services up
docker compose logs -f mcm-agent
```

At this point the SDK holds a live, Hub-signed certificate and trusts the Hub CA. mTLS is established in both directions.

Ask the Hub operator to confirm their side: the participant should appear in the Hub's Finance Portal with a position and a net debit cap. Until the Hub operator's onboarding step ran, the participant exists in the Connection Manager but not in the ledger — and no transfer will settle.

## Register a test party

To be found by other participants, register a party against the scheme's oracle. Using the bundled simulator, create the customer record and register its identifier. The exact host ports are set in the ITK `.env`; the calls go to the SDK's outbound API and the simulator's backend API.

```bash
# Create the party in the simulator backend
curl -X POST http://<participant-host>:<sim-port>/repository/parties \
  -H 'content-type: application/json' \
  -d '{"displayName":"Test User","firstName":"Test","lastName":"User",
       "idType":"MSISDN","idValue":"<msisdn>"}'

# Register it so other participants can discover it
curl -X POST http://<participant-host>:<sdk-outbound-port>/accounts \
  -H 'content-type: application/json' \
  -d '[{"idType":"MSISDN","idValue":"<msisdn>"}]' | jq .
```

Every entry in the response must show success. A failure here almost always means the **oracle was not registered on the Hub** — that is the Hub operator's setup, not the participant's. See [Hub configuration](../../adopter/deploy/hub.md#configure-the-hub).

Only a party that will **receive** needs registering. A sender's identifier is supplied in the transfer itself.

## Send a test transfer

With another participant registered as payee, send through the SDK's outbound API:

```bash
curl -X POST http://<participant-host>:<sdk-outbound-port>/transfers \
  -H 'content-type: application/json' \
  -d '{
    "homeTransactionId": "'"$(uuidgen)"'",
    "from": {"idType":"MSISDN","idValue":"<payer-msisdn>"},
    "to":   {"idType":"MSISDN","idValue":"<payee-msisdn>"},
    "amountType":"SEND", "currency":"<currency>", "amount":"10",
    "transactionType":"TRANSFER"
  }' | jq .
```

**Expected:** `"currentState": "COMPLETED"` with a `transferState` of `COMMITTED`. Party lookup, quote, and transfer together complete in well under a second.

The Hub operator can confirm from their side that positions moved by the transfer amount.

## If a transfer fails

Where it fails narrows the cause:

| Fails at | Likely cause |
|----------|-------------|
| Party lookup | Payee not registered, or the oracle is missing on the Hub |
| Quote | Connectivity or the payee participant is not reachable |
| Transfer, with a signature error | Message signing — usually not an onboarding problem |

A **signature error on the transfer while quotes succeed** is a known and separate class of issue on the Hub side, not something wrong with the participant's enrolment. See [JWS signing → When validation fails](../../architecture/jws-signing.md#a-different-failure-that-looks-the-same), and raise it with the Hub operator.

For anything mTLS-related — connection refused, certificate errors — see [Running → certificate health](../operate/running.md).
