# Known Issues — Operate

[doc](../../index.md) / [adopter](../index.md) / [operate](../index.md) / Known issues

**Audiences:** adopter (operate)

Recurring runtime issues, their causes, and what to do. Deployment-time issues are in [Deploy → Known issues](../deploy/known-issues.md).

## ALS reference data silently not seeded — transfers fail with FSPIOP 3003

The most consequential one to know about, because it fails much later than it happens.

**Symptoms** — a transfer needing party lookup returns `3003 — Oracle type:MSISDN not found`. Registering the oracle earlier returned `2001 — Cannot read properties of null (reading 'partyIdTypeId')`. Intermittent across fresh deploys — some work, some fail this way until fixed.

**Root cause** — the account-lookup-service admin runs schema migration then a seed phase. The seed phase can lose its MySQL connection mid-run (the HAProxy frontend reaps an idle connection between phases). The seed step swallows per-file failures, still reports success, and exits 0 — so the pod starts with empty `partyIdType`, `currency`, and `endpointType` tables. Every oracle registration then dereferences null, and every party lookup fails.

**Fix** — re-run the seed phase alone against the running admin pod; a fresh connection lands before any timeout:

```bash
ADMIN_POD=$(kubectl -n mojaloop get pods -l app.kubernetes.io/name=account-lookup-service-admin --no-headers | head -1 | awk '{print $1}')
kubectl -n mojaloop exec "$ADMIN_POD" -- sh -c 'cd /opt/app && npm run seed:run'
```

Verify the rows loaded — note the database is in `data`:

```bash
ROOT_PW=$(kubectl -n data get secret internal-mojaloop-db -o jsonpath='{.data.root}' | base64 -d)
kubectl -n data exec mojaloop-db-pxc-0 -c pxc -- \
  mysql -h 127.0.0.1 -u root -p"$ROOT_PW" -N -B -e \
  "USE account_lookup; SELECT 'partyIdType', COUNT(*) FROM partyIdType UNION SELECT 'currency', COUNT(*) FROM currency UNION SELECT 'endpointType', COUNT(*) FROM endpointType;"
```

Expect `partyIdType 10`, `currency 179`, `endpointType 6`, with a `MSISDN` row in `partyIdType`. Then re-run the hub-setup oracle registration.

**Prevention** — check these seed counts before running hub setup on a fresh Hub. A permanent fix (a retry around the seed step) is tracked in `discrepancies.md`.

## DFSP callback egress policy hijacks all port 80/443 traffic before any participant is enrolled

**Symptoms** — on a fresh Hub with no participants yet, pods in `mojaloop` cannot reach any external service on 80/443: S3 backups crash-loop, ACME challenges fail, image pulls break. Distinctive errors: `server gave HTTP response to HTTPS client`, or plain 404s with `server: envoy`. It stops the moment the first participant is enrolled.

**Root cause** — the `dfsp-callback-egress` network policy is rendered from the set of enrolled participants. With none, its FQDN list is empty, but its L4 match (ports 80/443) and Envoy redirect are still valid — so Cilium applies the redirect unconditionally to all egress from every pod in the namespace, into an Envoy listener with no routes.

**Fix** — enrolling any participant re-renders the policy correctly and the problem stops. For a Hub that will sit empty, delete the policy until then:

```bash
kubectl -n mojaloop delete ciliumnetworkpolicy dfsp-callback-egress
```

The Vault Agent recreates it on its next sync, so delete again as needed.

**Prevention** — a permanent template fix (one policy per participant, so the empty case renders nothing) is tracked in `discrepancies.md` item 5.

## Kratos migration fails intermittently on fresh deploy

**Symptoms** — Kratos crash-loops with MySQL access-denied or migration errors on a fresh Hub.

**Root cause** — Kratos starts before the MySQL operator has finished creating the `kratos` user. The operator creates users asynchronously *after* the cluster reports ready, so the health gate is not sufficient on its own.

**Fix** — the HelmRelease allows 15 minutes for this. If it is still crash-looping after that:

```bash
flux suspend helmrelease kratos -n flux-system
flux resume helmrelease kratos -n flux-system
```

This is the same class of race as the [Mojaloop migration issue](../deploy/known-issues.md#mojaloop-migration-fails-with-backofflimitexceeded-on-a-fresh-deploy).

## MCM returns HTTP 500 on Vault-backed operations

**Symptoms** — MCM returns 500 for anything touching Vault (participant enrolment, certificate management). Vault's audit log shows an expired token.

**Root cause** — MCM's Vault client does not renew its token. The Kubernetes auth token has a 768-hour (32-day) TTL. If the pod runs longer than that without restarting, the token expires.

**Fix** — restart MCM:

```bash
kubectl rollout restart deploy/mcm -n mcm
```

**Prevention** — MCM restarts on artifact updates, so normal deployment cycles cover the TTL. If you go more than ~30 days between updates, watch MCM's pod age and restart it periodically.

## Metrics gap after a Thanos Receive restart

**Symptoms** — a gap in Grafana metrics around a Thanos Receive pod restart.

**Root cause** — Receive buffers recent samples in a write-ahead log and flushes complete blocks to object storage about every two hours. A crash before a flush loses the buffered samples.

**Fix** — WAL replay on restart recovers most of it; a gap of up to two hours is expected and cannot be recovered. Metrics are not a system of record.

**Prevention** — give Receive enough memory to avoid OOM kills, the usual cause of unexpected restarts. Watch its restart count on the Kubernetes Cluster dashboard.
