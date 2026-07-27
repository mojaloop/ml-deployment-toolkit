# Monitoring

[doc](../../index.md) / [adopter](../index.md) / [operate](../index.md) / Monitoring

**Audiences:** adopter (operate)

Where to look, in what order, and what "healthy" looks like. For how the observability stack is built, see [Observability architecture](../../architecture/observability.md).

- [Where monitoring lives](#where-monitoring-lives)
- [Start here: Switch Overview](#start-here-switch-overview)
- [Dashboards](#dashboards)
- [What to check first](#what-to-check-first)
- [Log queries](#log-queries)
- [Node and OS health](#node-and-os-health)
- [Alerting](#alerting)

## Where monitoring lives

Grafana runs on the **Tooling Cluster**, at `https://grafana.int.<tooling-domain>`, with the admin password from `GRAFANA_ADMIN_PASSWORD`.

A Hub ships metrics, logs, and traces to the Tooling Cluster — it runs no Grafana of its own. A deployment without a Tooling Cluster has no aggregated dashboard; a Hub keeps running, but there is no central place to watch it.

## Start here: Switch Overview

Open the **Switch Overview** dashboard first. It is the intended landing page — a single view of the whole Hub, with drill-downs into everything else. When someone reports a problem, begin here, not in a service-specific dashboard.

## Dashboards

Thirty dashboards ship pre-provisioned, in five folders:

| Folder | Use it for |
|--------|-----------|
| **Home** | Switch Overview — the entry point |
| **Infrastructure** | Nodes, cluster, pods, CoreDNS, Cilium, API server, storage, Proxmox hosts |
| **Data Layer** | MySQL, PXC/Galera, Kafka, MongoDB, Redis |
| **Platform** | cert-manager, external-dns, Vault, Ory, Oathkeeper, Flux |
| **Mojaloop** | Transfer pipeline, account lookup, quoting, participant mTLS gateway, participant overview |

The full list and folder breakdown is in [Observability → Dashboards](../../architecture/observability.md#dashboards).

## What to check first

A rough order when something is wrong, working from the symptom toward the cause:

1. **Switch Overview** — is the problem cluster-wide or one service?
2. **Transfer pipeline** (Mojaloop) — if transfers are failing, this shows where in the flow
3. **Data Layer** — MySQL and Kafka underpin everything; a database problem surfaces as many unrelated application symptoms
4. **Infrastructure → Kubernetes Cluster** — pod restarts, resource pressure, evictions
5. **Platform** — if auth or certificates are involved

The recurring trap: a data-layer problem looks like an application problem. If several unrelated Mojaloop services degrade at once, check MySQL and Kafka before investigating any one service.

## Log queries

Use Grafana's **Explore** tab with the Loki datasource. Note the real namespaces — the data layer is in `data`, auth in `ory`:

```logql
# Errors across the Mojaloop app namespace
{namespace="mojaloop"} |= "error" | logfmt

# A specific service
{namespace="mojaloop", pod=~"moja-central-ledger.*"}

# Data layer
{namespace="data"} |= "error"

# Vault Agent (participant certificate rendering)
{namespace="mcm", container="vault-agent"}

# Flux reconciliation problems
{namespace="flux-system"} |= "error"
```

Logs are correlated with traces: a trace ID in a log line links straight into Tempo, and a span links back to its logs. Following a single transfer end to end usually starts from a log line, not a dashboard.

## Node and OS health

Metrics stop at the Kubernetes boundary. For the Talos nodes underneath, use `talosctl`:

```bash
talosctl --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip> health
talosctl --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip> dashboard
```

The dashboard is a live per-node view of CPU, memory, network, and services. Reach for it when a node problem is suspected but Kubernetes still reports the node Ready — the layer below Kubernetes is invisible to Grafana.

## Alerting

**22 alert rules ship and run** — across infrastructure, platform, data layer, and Mojaloop. They evaluate whether or not anyone is listening.

**Delivery is separate, and silent if unconfigured.** Alerts go nowhere without the SMTP and Telegram secrets set on the Tooling Cluster. If no alert has ever arrived, the first thing to check is whether delivery is configured — not whether the rules exist.

```
SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, ALERT_EMAIL_FROM, ALERT_EMAIL_TO
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
```

Everything routes to one policy, grouped by alert name and cluster, repeating every 4 hours. Confirm delivery by triggering a test through the contact point in Grafana rather than waiting for a real alert to find out it was never wired. See [Observability → Alerting](../../architecture/observability.md#alerting).

## Retention

Metrics, logs, and traces are kept **7 days** each. Adequate for a lab; production schemes with audit obligations will want longer, which is a retention and storage change — see [Observability → Retention](../../architecture/observability.md#retention).
