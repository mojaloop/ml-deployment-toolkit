# Known Issues — Operate

[doc](../../index.md) / [adopter](../index.md) / [operate](../index.md) / Known issues

**Audiences:** adopter (operate)

Recurring runtime issues, their causes, and what to do. Deployment-time issues are in [Deploy → Known issues](../deploy/known-issues.md).

### ALS reference data silently not seeded — transfers fail with FSPIOP 3003 (account-lookup-service)

The most consequential one to know about, because it fails much later than it happens.

**Symptoms:** A transfer needing party lookup returns `3003 — Oracle type:MSISDN not found`. Registering the oracle earlier returned `2001 — Cannot read properties of null (reading 'partyIdTypeId')`. Intermittent across fresh deploys — some work, some fail this way until fixed.
**Root cause:** The account-lookup-service admin runs schema migration then a seed phase. The seed phase can lose its MySQL connection mid-run (the HAProxy frontend reaps an idle connection between phases). The seed step swallows per-file failures, still reports success, and exits 0 — so the pod starts with empty `partyIdType`, `currency`, and `endpointType` tables. Every oracle registration then dereferences null, and every party lookup fails.
**Fix/workaround:** Re-run the seed phase alone against the running admin pod; a fresh connection lands before any timeout:

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
**Prevention:** Check these seed counts before running hub setup on a fresh Hub.

### Kratos migration fails intermittently on fresh deploy (Kratos, MySQL operator)

**Symptoms:** Kratos crash-loops with MySQL access-denied or migration errors on a fresh Hub.
**Root cause:** Kratos starts before the MySQL operator has finished creating the `kratos` user. The operator creates users asynchronously, and in rare cases the last users land after the cluster's health gate opens ([ADR-019](../../architecture/decisions/019-health-gated-reconciliation.md)).
**Fix/workaround:** The HelmRelease allows 15 minutes for this. If it is still crash-looping after that:

```bash
flux suspend helmrelease kratos -n flux-system
flux resume helmrelease kratos -n flux-system
```

**Prevention:** None needed beyond patience — the retry budget absorbs it on virtually every deploy.

### Lost or expired cluster access — kubeconfig and talosconfig (Talos)

**Symptoms:** One of three shapes, all the same underlying story:

- `kubectl` fails with connection refused dialing `127.0.0.1:1` — the kubeconfig is the Makefile-seeded placeholder.
- `../artifacts/<env>/kubernetes/kubeconfig` or `../artifacts/<env>/talos-config/talosconfig` is missing entirely.
- `talosctl` or `kubectl` fails with `x509: certificate has expired`.

**Root cause:** Two independent facts. First, both files live under `../artifacts/<env>/` — outside both the clone and the environment repository, versioned by nothing — so a cleanup or a new workstation loses them; and if any `make` target runs before the kubeconfig is restored, the Makefile seeds a placeholder pointing at `https://127.0.0.1:1` (so Terraform can plan) — valid YAML, so `kubectl` accepts it and dials a dead endpoint. Second, both client certificates are issued for **one year**, while the Talos CA is valid for ten; Talos auto-rotates everything cluster-internal, so only these two client credentials ever age. Check remaining validity anytime with `talosctl config info`.
**Fix/workaround:** Restore access from the bottom up. Each step is only needed if the layer below it is broken.

*Terraform path (all providers):* `make plan-apply ENV=<env>` regenerates everything — the Talos provider re-issues expired client certificates on refresh and rewrites both files under `../artifacts/<env>/`. It is the **infra** stack that does this, so `make apply-config` will not help here. On managed providers (AWS, DigitalOcean) this is the only path.

*Manual path (Talos environments)* — needs only the `talosctl` binary and reachability to the cluster, no working Terraform:

1. **If the talosconfig is lost or expired**, mint a fresh one from the machine secrets bundle (written by every deploy to `../artifacts/<env>/talos-secrets/secrets.yaml`). This step is offline — it does not touch the cluster:

   ```bash
   talosctl gen config <cluster-name> https://<vip>:6443 \
     --with-secrets ../artifacts/<env>/talos-secrets/secrets.yaml \
     --output-types talosconfig \
     -o ../artifacts/<env>/talos-config/talosconfig --force
   ```

   Note that `make clean ENV=<env>` deletes `talos-secrets/` along with the other generated artifacts — after a clean, only the Terraform path remains until the next apply rewrites the bundle.

2. **Regenerate the kubeconfig** using the (now valid) talosconfig:

   ```bash
   talosctl kubeconfig \
     --talosconfig ../artifacts/<env>/talos-config/talosconfig \
     -n <vip> -e <vip> \
     --merge=false -f \
     ../artifacts/<env>/kubernetes/kubeconfig
   ```

**The hard boundary:** every recovery above roots in the machine secrets, held in `secrets.yaml` and the Terraform state. If both are gone, there is no door: the Talos API is mTLS-only with no password or console fallback, and the only way forward is a rebuild per [Disaster recovery](../recover/disaster-recovery.md). The state backup there is not optional.
**Prevention:** The files themselves need no backup beyond the Terraform state (see [What the adopter must keep](../recover/disaster-recovery.md#what-the-adopter-must-keep)) — they are regenerable. The certificates do need a calendar: any infra-stack apply within the year re-issues them, but a cluster left untouched longer than that crosses the expiry — run `talosctl config info` when in doubt, and refresh before the date it prints.

### MCM returns HTTP 500 on Vault-backed operations (MCM)

**Symptoms:** MCM returns 500 for anything touching Vault (participant enrolment, certificate management). Vault's audit log shows an expired token.
**Root cause:** MCM's Vault client does not renew its token. The Kubernetes auth token has a 768-hour (32-day) TTL. If the pod runs longer than that without restarting, the token expires.
**Fix/workaround:** Restart the MCM API:

```bash
kubectl rollout restart deploy/mcm-connection-manager-api -n mcm
```

**Prevention:** MCM restarts on artifact updates, so normal deployment cycles cover the TTL. If more than ~30 days pass between updates, watch the pod age and restart it periodically.

### Metrics gap after a Thanos Receive restart (Thanos)

**Symptoms:** A gap in Grafana metrics around a Thanos Receive pod restart.
**Root cause:** Receive buffers recent samples in a write-ahead log and flushes complete blocks to object storage about every two hours. A crash before a flush loses the buffered samples.
**Fix/workaround:** WAL replay on restart recovers most of it; a gap of up to two hours is expected and cannot be recovered. Metrics are not a system of record.
**Prevention:** Give Receive enough memory to avoid OOM kills, the usual cause of unexpected restarts. Watch its restart count on the Kubernetes Cluster dashboard.
