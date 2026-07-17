# Known Issues (Operations)

[docs](../index.md) / [operations](index.md) / Known Issues

**Audiences:** adopter (operate)

Runtime known issues encountered during ML Deployment Toolkit operations. For deployment issues, see [adopter known issues](../adopter/known-issues.md). For platform build issues, see [platform known issues](../platform/known-issues.md).

---

### MCM Vault token expiry -- HTTP 500 on Vault-backed operations (MCM v3.1.2)

**Symptoms:**
MCM API returns HTTP 500 for all operations that read/write Vault (DFSP enrollment, certificate management). Vault audit log shows an expired token.

**Root cause:**
MCM uses the `node-vault` library which never renews Vault tokens. The Vault Kubernetes auth token has a default TTL that expires while the MCM pod is running.

**Fix/workaround:**
The Vault K8s auth role `mcm` is configured with `ttl: 768h` (32 days). If the MCM pod has been running longer than the TTL without a restart, restart it:

```bash
kubectl rollout restart deploy/mcm -n mcm
```

**Prevention:**
MCM pods restart on artifact updates during Flux reconciliation. The 768h TTL covers normal deployment cycles. If deployments are infrequent (more than 30 days between updates), monitor MCM pod age and schedule periodic restarts.

---

### Thanos Receive data loss window (~2 hours)

**Symptoms:**
Gap in metrics data visible in Grafana after a Thanos Receive pod crash or restart. Queries for the period around the restart return no data or partial data.

**Root cause:**
Thanos Receive writes TSDB blocks to S3 every ~2 hours. Until a block is complete and uploaded, data exists only in the local WAL (write-ahead log). A pod crash loses uncommitted WAL data.

**Fix/workaround:**
WAL replay on restart recovers most data. Gaps of up to 2 hours are expected after crashes and cannot be recovered.

**Prevention:**
Ensure the Receive pod has sufficient memory to avoid OOM kills -- this is the most common cause of unexpected restarts. Monitor Receive pod restarts via the Kubernetes Cluster dashboard in Grafana.

---

### Kratos intermittent MySQL migration failure (Kratos v1.3.1)

**Symptoms:**
Kratos pod crash-loops with MySQL migration errors on fresh deploy. Logs show `Access denied` or schema migration failures.

**Root cause:**
Race condition between Kratos startup and PXC operator user creation. Kratos migration starts before the PXC operator finishes creating the `kratos` database user (~7-10 minutes after PXC CR creation).

**Fix/workaround:**
The HelmRelease timeout is set to 15 minutes to allow PXC user creation to complete. If the pod is still crash-looping after 15 minutes, suspend and resume:

```bash
flux suspend helmrelease kratos -n flux-system
flux resume helmrelease kratos -n flux-system
```

**Prevention:**
The `env-data` kustomization has a CEL health check gating on PXC `status.state == 'ready'`. Ensure the `env-auth` kustomization depends on `env-data` in the Flux dependency chain. The race occurs because PXC reporting `ready` does not guarantee all declarative users have been created -- the operator processes `spec.users[]` asynchronously after cluster readiness.

---

### Keycloak CrashLoopBackOff -- Liquibase migration error on stale database

**Symptoms:**
Keycloak pod crash-loops immediately after init containers complete. Logs show a Liquibase `MigrationFailedException` with `Unknown column 'RESOURCE_SERVER_CLIENT_ID' in 'RESOURCE_SERVER_POLICY'`.

**Root cause:**
The `keycloak` MySQL database contains schema from a previous Keycloak version that is incompatible with the version being deployed. This happens when a cluster is redeployed (`make destroy && make plan-apply`) but the PXC persistent volume survives, retaining the old database. The new Keycloak tries to apply Liquibase migrations on top of the stale schema and hits column/table mismatches.

**Fix/workaround:**
Drop and recreate the keycloak database, then restart the pod:

```bash
ROOT_PW=$(kubectl -n mojaloop get secret internal-mojaloop-db -o jsonpath='{.data.root}' | base64 -d)
kubectl -n mojaloop exec -it mojaloop-db-pxc-0 -c pxc -- mysql -h 127.0.0.1 -u root -p"$ROOT_PW" \
  -e "DROP DATABASE keycloak; CREATE DATABASE keycloak;"
kubectl -n keycloak delete pod keycloak-0
```

Keycloak will run its full migration set on the empty database and start cleanly. The Keycloak operator will then re-import realms via `KeycloakRealmImport` CRs.

**Prevention:**
When redeploying from scratch, either wipe PXC PVCs before `make plan-apply`, or use `make restore` to load a backup matching the current Keycloak version. This issue does not occur on genuinely fresh deploys (new PVCs) or on upgrades where the schema version sequence is contiguous.

---

### DFSP callback egress policy hijacks all port 80/443 traffic when no DFSPs enrolled

**Symptoms:**
Pods in the `mojaloop` namespace cannot reach any external service on ports 80/443 -- including S3 backups (PITR and scheduled backup jobs crash-loop), Let's Encrypt ACME challenges, upstream image pulls. Distinctive error pattern: `http: server gave HTTP response to HTTPS client` or `SSL: packet length too long` from HTTPS clients, and plain HTTP 404 with `server: envoy` from HTTP clients. Occurs on fresh deploys before any DFSP is onboarded. Stops as soon as at least one DFSP is enrolled in MCM.

**Root cause:**
`gitops/env-app/mcm/vault-agent-configmap.yaml` renders the `dfsp-callback-egress` CiliumNetworkPolicy with `toFQDNs` populated by a `{{ range secrets "secret/onboarding_pm4mls/" }}` loop. With no DFSPs enrolled, the range emits nothing and `toFQDNs:` renders as null. Combined with `endpointSelector: {}` (all pods in namespace) and `toPorts.ports: [80, 443]` plus a listener redirect to the `dfsp-callback-mtls` CEC, an empty L3 selector plus a valid L4 match causes Cilium to apply the L7 redirect **unconditionally**. All port 80/443 egress from every pod in the namespace is intercepted by an Envoy listener whose `route_config.virtual_hosts` is also empty -- which 404s plain HTTP and returns garbled HTTP to TLS clients.

The policy became dangerous from commit `c74ffcde` ("fix extapi", 2026-04-07). Earlier versions of the template emitted the listener without an explicit `ports:` array, which Cilium treated as an invalid/no-op L4 match, so empty `toFQDNs` was harmless. Adding `ports: [80, 443]` gave the rule a valid L4 selector and turned the empty-FQDN case into a catch-all.

**Fix/workaround:**
Enrolling any DFSP in MCM causes the vault-agent to re-render the policy with a scoped `toFQDNs`, and the hijack stops. For empty-DFSP environments, delete the policy until the template is fixed:

```bash
kubectl -n mojaloop delete ciliumnetworkpolicy dfsp-callback-egress
```

The vault-agent will re-create it on its next sync. Delete it again as needed, or suspend the vault-agent, until the permanent fix ships.

**Prevention (permanent fix options):**
Two viable template shapes, in descending order of robustness:

1. **One CNP per DFSP (recommended).** Move the entire listener egress rule inside the `{{ range }}` loop so each enrolled DFSP renders its own CNP (`dfsp-callback-egress-<dfsp>`) with a single-FQDN `toFQDNs` entry. When no DFSPs are enrolled, zero policies are rendered -- the empty-catchall case is unrepresentable by construction. Per-DFSP lifecycle also becomes cleaner: enrolling or revoking a single DFSP touches only that DFSP's policy. Keep the DNS-egress and `toEntities: [world, cluster]` rules in a separate always-rendered static policy.

2. **`{{ if }}` guard (hotfix).** Wrap the listener egress rule in `{{ if gt (len (secrets "secret/onboarding_pm4mls/")) 0 }}` so it's emitted only when at least one DFSP exists. One-line change, keeps the current single-CNP shape, but leaves the "range output drives the rule's scope" pattern in place -- a future template edit could reintroduce a similar bug.

Defense-in-depth (should accompany either fix): narrow `endpointSelector: {}` to only the pods that actually make DFSP callbacks (`ml-api-adapter`, `central-ledger`, `sdk-scheme-adapter-*`). This limits blast radius if the template misfires again -- infrastructure pods (PITR, operators, vault-agent itself) stay out of scope regardless of what the rule says.

---

### ALS reference-data seeds silently skipped -- transfers fail with FSPIOP 3003 on fresh deploy

**Symptoms:**
Any transfer that requires party lookup returns FSPIOP error `3003 - Add Party information error - Oracle type:MSISDN not found` (HTTP 500). Prior attempts to register the oracle via the manual `new_hub.json` hub-setup collection (`POST /oracles`) return `2001 - Internal server error - Cannot read properties of null (reading 'partyIdTypeId')`. Intermittent across deployments -- some fresh clusters work fine, others consistently fail with this symptom until manually remediated.

**Root cause:**
The `account-lookup-service-admin` pod runs `npm run migrate` in its `run-migration` init container, which resolves to `run-s migrate:latest seed:run` (per the upstream chart's init script). The schema phase (`migrate:latest`) succeeds, but the seed phase (`seed:run`) loses its MySQL connection mid-run:

```
> account-lookup-service@17.15.2 migrate
> run-s migrate:latest seed:run

Batch 1 run: 8 migrations
Uploading seeds for currency has failed: Error: Connection lost: The server closed the connection.
Uploading seeds for endpointType has failed: Error: Connection lost: ...
Uploading seeds for partyIdType has failed: Error: Connection lost: ...
Ran 3 seed files
```

The race is between the schema-migration phase finishing and the knex pool handing an idle connection to the seed phase; the PXC HAProxy frontend reaps the connection and every seed insert hits a dead socket. Knex's `seed:run` swallows per-file failures, still reports `"Ran 3 seed files"`, and exits 0 -- so the init container passes, ALS starts, and `account_lookup.partyIdType` / `currency` / `endpointType` are all empty. Any subsequent `POST /oracles` in the ALS admin dereferences null from `SELECT partyIdTypeId FROM partyIdType WHERE name='MSISDN'` and 2001s. No oracles can ever be registered, so every party lookup 3003s.

**Fix/workaround:**
Re-run the seed phase alone against the existing ALS admin pod -- this takes ~1 second and the fresh connection lands before any idle timeout fires:

```bash
ADMIN_POD=$(kubectl -n mojaloop get pods -l app.kubernetes.io/name=account-lookup-service-admin --no-headers | head -1 | awk '{print $1}')
kubectl -n mojaloop exec "$ADMIN_POD" -- sh -c 'cd /opt/app && npm run seed:run'
```

Verify seed rows loaded:

```bash
ROOT_PW=$(kubectl -n mojaloop get secret internal-mojaloop-db -o jsonpath='{.data.root}' | base64 -d)
kubectl -n mojaloop exec mojaloop-db-pxc-0 -c pxc -- \
  mysql -h 127.0.0.1 -u root -p"$ROOT_PW" -N -B -e \
  "USE account_lookup; SELECT 'partyIdType', COUNT(*) FROM partyIdType UNION SELECT 'currency', COUNT(*) FROM currency UNION SELECT 'endpointType', COUNT(*) FROM endpointType;"
```

Expected output: `partyIdType 10`, `currency 179`, `endpointType 6`. `partyIdType` must include a row with `name='MSISDN'`.

After seeds load, re-run the manual hub setup (`new_hub.json` via TTK) to register the MSISDN Oracle endpoint. `POST /oracles` will now return 201 Created.

**Prevention:**
Two durable options; neither is implemented yet:

1. **Wrap `seed:run` in a retry inside the HelmRelease init override.** Extend `gitops/env-app/mojaloop/helmrelease.yaml`'s ALS section to replace the chart's single `npm run migrate` init with a two-step init: (a) `npm run migrate:latest`, then (b) `until npm run seed:run; do sleep 5; done` on a fresh connection. Keeps knex seeds as the source of truth; just tolerates the race.
2. **Flux Kustomize Job that seeds via raw SQL.** Standalone Job that inserts the stable reference rows idempotently, independent of the chart's init. Bypasses knex entirely; most defensive but duplicates chart responsibility.

Option 1 is the right upstream shape. Until either lands, treat this as a post-deploy manual step and confirm seed row counts before running the hub-setup collection.
