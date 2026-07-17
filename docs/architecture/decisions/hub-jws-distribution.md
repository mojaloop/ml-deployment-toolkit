# Hub JWS public key distribution

## Problem

Transfers between DFSPs fail at the fulfil step with:

```
Inbound request failed JWS validation
JWS public key for 'Hub' not available. Unable to verify JWS.
Only have keys for: ["dfsp-201","dfsp-202"]
```

The hub's `ml-api-adapter-handler-notification` signs the `PUT /transfers/{id}` callback with `fspiop-source: Hub` using its JWS private key. The payer DFSP's sdk-scheme-adapter rejects the callback because it has no public key for the Hub in its in-memory keyring.

## Root cause

Three gaps in iac3, none in upstream code:

1. **Hub JWS pub key is never uploaded to MCM.** Nothing in the pipeline calls `POST /api/hub/jwscerts`.
2. **Per-service auto-generated JWS keys.** Upstream Mojaloop helm charts auto-generate a separate JWS keypair per service when `endpointSecurity.jwsSigningKeySecret` is null. Even if you uploaded one pub key, the others would not match.
3. **Identity mismatch.** The switch signs with `fspiop-source = HUB_PARTICIPANT.NAME = "Hub"`. MCM identifies the switch via `SWITCH_ID = "hub-<domain>"`. The onboarding toolkit uses `HUB_NAME = onboarding_hub_name = "hub"`. Three different strings for the same actor.

The upstream plumbing is complete: MCM stores the Hub as a virtual DFSP with `dfspId = SWITCH_ID` (`connection-manager-api/src/service/JWSCertsService.js:91-112`). `GET /api/dfsps/jwscerts` (already polled by the mcm-agent every ~60s) returns it alongside real DFSPs. The agent's `pullingPeerJWS` → `NOTIFYING_PEER_JWS` → `UPLOAD_PEER_JWS` flow ships it to the SDK unchanged. The SDK indexes by `dfspId`. So once all three names align and the pub key lands in MCM, distribution is automatic.

## Design

**Identity.** Pick one string. Use `"Hub"` (upstream chart default — minimises overrides). Apply in three places:

- Mojaloop chart value `global.config.hub_participant.name` → drives `HUB_PARTICIPANT.NAME` on every switch service that signs/validates
- MCM env `SWITCH_ID` → drives the `dfspId` under which the Hub's JWS pub key is stored in MCM
- Onboarding toolkit `HUB_NAME` → already wired via `onboarding_hub_name`

Promote the existing Terraform variable `onboarding_hub_name` to `hub_participant_name` (same variable, broader semantic scope). Stays in `.env` for now (promotion to `config.yaml` can follow if the scope grows).

**Keypair.** One shared Secret `switch-jws` in `mojaloop` namespace, issued by the existing cert-manager ClusterIssuer `vault-pki-issuer` (already used for `extapi-tls`). All switch signers mount the same Secret via helm value `endpointSecurity.jwsSigningKeySecret`. Rotation handled by cert-manager.

**Distribution.** A small `jws-pubkey-job` Deployment in `mojaloop` namespace (pattern from `_legacy/test-yev/sw-source/apps/mojaloop/switch-jws-deployment.yaml`) with three initContainers:

1. Read `tls.crt` from `switch-jws` Secret
2. Extract RSA public key via `openssl x509 -pubkey -noout`
3. `POST /api/hub/jwscerts` body `{publicKey, createdAt}` to `mcm-connection-manager-api.mcm.svc:3001`

Stakater Reloader watches `switch-jws` and restarts this pod (and every switch signer) on rotation. Next pub key automatically re-uploaded.

## End-to-end flow

```
cert-manager Certificate `switch-jws`
  → Vault PKI signs CSR (vault-pki-issuer, pki/sign/server-cert-role)
  → k8s Secret `switch-jws` (tls.key + tls.crt) in mojaloop ns
     ├─ mounted by all switch signers (jwsSigningKeySecret)
     │    → outbound callbacks signed with fspiop-source: <hub_participant_name>
     └─ read by jws-pubkey-job
          → POST /api/hub/jwscerts to MCM
          → MCM stores as DFSP with dfspId = SWITCH_ID = <hub_participant_name>
          → GET /api/dfsps/jwscerts now returns [Hub, dfsp-201, dfsp-202]
          → mcm-agent polls (~60s), detects change
          → ControlServer pushes UPLOAD_PEER_JWS to sdk-scheme-adapter
          → SDK peerJWSKeys["<hub_participant_name>"] = <pub key>
          → inbound JWS validation on fulfils succeeds
```

## Alignment with other cert management

Same pattern as the extapi mTLS cert (`gitops/env-app/routes/extapi-cert.yaml`). Both use `vault-pki-issuer`, both store in a k8s Secret in `mojaloop` ns, both auto-renew. The JWS cert just doesn't need EKU=serverAuth semantics — only the public key is consumed — but reusing the server-cert-role is harmless; the cert itself is never TLS-validated. A dedicated `jws-signing-role` with longer TTL is a possible future tune (Phase 4), not needed for correctness.

ESO (external-secrets operator) is not used here. ESO syncs *existing* secrets from a backend. For *newly-issued* keypairs, cert-manager with a Vault ClusterIssuer is the direct path — Vault signs, cert-manager writes the k8s Secret, no intermediate copy.

## Plan

### Phase 1 — rename and align identity

Changes:

| File | Change |
|---|---|
| `src/variables.tf:228` | Rename `onboarding_hub_name` → `hub_participant_name`, default `"Hub"` |
| `src/main.tf:167` | Update reference |
| `src/modules/flux-config/variables.tf:370` | Rename module variable |
| `src/modules/flux-config/main.tf:96` | Update ConfigMap key |
| `Makefile:55` | Rename `TF_VAR_onboarding_hub_name` → `TF_VAR_hub_participant_name`, source env `HUB_PARTICIPANT_NAME` |
| `config/environments/*/.env.sample` | Rename `ONBOARDING_HUB_NAME` → `HUB_PARTICIPANT_NAME`, default `"Hub"` |
| `config/environments/ml-test/.env:75` | Same, set to `"Hub"` |
| `gitops/env-app/mcm/vault-agent-configmap.yaml:380` | `"HUB_NAME": "${hub_participant_name}"` |
| `gitops/env-app/mcm/helmrelease.yaml:119` | `SWITCH_ID: "${hub_participant_name}"` |
| `gitops/env-app/mojaloop/helmrelease.yaml` | Add `values.global.config.hub_participant.name: "${hub_participant_name}"` override |

Validation: `make plan-apply ENV=ml-test && make push-gitops ENV=ml-test && flux reconcile source oci ml-gitops`. Then:

```bash
kubectl -n mcm get deploy mcm-connection-manager-api -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SWITCH_ID")].value}'
kubectl -n mojaloop get cm moja-ml-api-adapter-handler-notification-config -o jsonpath='{.data.default\.json}' | jq -r .HUB_PARTICIPANT.NAME
```
All must return `"Hub"`. Transfers still fail at this point (expected — pub key not yet registered in MCM).

### Phase 2 — shared JWS keypair

Changes:

| File | Change |
|---|---|
| `gitops/env-app/mojaloop/switch-jws-cert.yaml` | New `Certificate` CR, `issuerRef: vault-pki-issuer`, `secretName: switch-jws`, 4096-bit RSA |
| `gitops/env-app/mojaloop/helmrelease.yaml` | For each of: ml-api-adapter-handler-notification, quoting-service (+handler), account-lookup-service (+admin), bulk-api-adapter-handler-notification — set `config.endpointSecurity.jwsSigningKeySecret: {name: switch-jws, key: tls.key}` |

Validation: Secret exists; pods reference it; pods restart cleanly.

### Phase 3 — distribution

Changes:

| File | Change |
|---|---|
| `gitops/platform/stakater-reloader/helmrelease.yaml` | New HelmRelease for Stakater Reloader (controller currently absent; pre-existing annotations in Keto/Kratos yamls will start working too) |
| `gitops/platform/kustomization.yaml` | Add reloader subdir |
| `gitops/env-app/mojaloop/switch-jws-pubkey-job.yaml` | New Deployment adapted from test-yev, annotated `secret.reloader.stakater.com/reload: switch-jws` |
| `gitops/env-app/mojaloop/helmrelease.yaml` | Add `podAnnotations: secret.reloader.stakater.com/reload: switch-jws` on all switch signers |

Validation:

```bash
kubectl -n mcm port-forward svc/mcm-connection-manager-api 3001:3001 &
curl -s localhost:3001/api/dfsps/jwscerts | jq '.[].dfspId'   # expect: ["Hub", "dfsp-201", "dfsp-202"]

docker logs dfsp-202-mcm-agent-1 2>&1 | grep getPeerDFSPJWSCertificates | tail -1
# expect data array to include Hub

# Re-run the transfer curl. Should succeed (no 504 timeout).
```

### Phase 4 — cleanup

- Delete chart-generated per-service JWS secrets (`moja-ml-api-adapter-handler-notification-jws-signing-key`, etc.)
- Optionally add a dedicated `jws-signing-role` in Vault PKI (TF module) with TTL 8760h
- Document the three-way identity alignment constraint in `docs/architecture/networking.md` or `dfsp-mtls.md`

## Risks

- **Oathkeeper on `/api/hub/jwscerts`**: test-yev calls it unauthenticated cluster-internal. iac3 fronts MCM with oathkeeper. Verify `gitops/env-app/mcm/oathkeeper-rules.yaml` exposes `POST /api/hub/jwscerts` cluster-internal, or add a token-fetch step to the uploader.
- **Central-ledger hub participant name**: renaming `HUB_PARTICIPANT.NAME` mid-lifecycle may leave a stale row in central-ledger DB. Safest to apply on a fresh DB. For this session: current cluster has `HUB_PARTICIPANT.NAME: "Hub"` (we're keeping the same value), so no impact.
- **Ordering**: Phase 1 without Phase 3 is safe (no new failures). Phase 3 without Phase 1 does not work (name mismatch).

## Known orthogonal issue (not addressed by this work)

After this fix, end-to-end transfers may still fail at the **transfer prepare** step with `3105 Invalid signature` on the payee DFSP's inbound. This is **separate** from Hub JWS distribution and would fail identically in the pre-fix world — the Hub JWS timeout just masked it first in our tests.

Root cause: Mojaloop's `ml-api-adapter-handler-notification` consumes the transfer prepare from Kafka, deserializes the JSON payload, and re-serializes it when POSTing to the payee DFSP. The re-serialized JSON bytes don't match the original payer-signed bytes (different key order or whitespace), so the JWS signature — computed over exact bytes — no longer verifies with the payer's public key.

Evidence in the live cluster:
- **quote POST** from payer (dfsp-202) to payee (dfsp-201) validates correctly — the quoting-service proxies HTTP directly, preserving body bytes
- **transfer POST** from payer to payee fails validation — the notification handler reconstructs the body from Kafka message fields

Workarounds to investigate (out of scope for this plan):
- Set `VALIDATE_INBOUND_JWS=false` on the sdk-scheme-adapter for a PM4ML-style deployment
- Ensure central-ledger preserves raw payload bytes through the Kafka pipeline
- Use an ISO 20022 canonicalization layer upstream of JWS signing

Hub JWS distribution itself is verified working:
- `GET /api/dfsps/jwscerts` on MCM returns the Hub entry with `validationState: VALID`
- Each DFSP's mcm-agent polls and pushes the full set (including Hub) to its SDK via ControlServer
- Hub-signed callbacks (e.g. `PUT /transfers/{id}/error` with `fspiop-source: Hub`) validate successfully on the payee DFSP's SDK after the fix
