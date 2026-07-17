# Monitoring

[docs](../index.md) / [operations](index.md) / Monitoring

**Audiences:** adopter (operate)

---

## Talos node dashboard

On-prem clusters (Proxmox) run Talos Linux. The `talosctl dashboard` command provides a real-time TUI showing CPU, memory, network, and process activity per node.

```bash
talosctl dashboard --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip>
```

The VIP is the `cluster.vip` value from `config/environments/<env>/config.yaml`. Example:

```bash
talosctl dashboard --talosconfig artifacts/ml-test/talos-config/talosconfig -n 192.168.88.14
```

Other useful `talosctl` commands:

```bash
# Node health and version
talosctl health --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip>
talosctl version --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip>

# Kernel logs (dmesg)
talosctl dmesg --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip>

# Running services
talosctl services --talosconfig artifacts/<env>/talos-config/talosconfig -n <vip>
```

---

## Accessing Grafana

```bash
export KUBECONFIG=$(pwd)/artifacts/<env>/kubernetes/kubeconfig

# Get admin password
kubectl get secret cluster-secrets -n flux-system \
  -o jsonpath='{.data.grafana_admin_password}' | base64 -d
```

Navigate to `https://grafana.int.${domain}`, login with `admin` + the password from above.

## Dashboard inventory

16+ dashboards across 4 folders.

### Infrastructure

| Dashboard | What it shows |
|-----------|---------------|
| Kubernetes Cluster | Node count, pod count, resource utilization |
| Node Overview | Per-node CPU, memory, disk, network |
| Pod Resources | Per-pod CPU/memory requests vs limits vs actual |
| CoreDNS | DNS query rate, errors, latency |
| Cilium Network | Network policies, drops, forwarded packets |
| Kube API Server | API request rate, latency, errors |
| Kubelet | Pod start latency, running pods/containers |
| Persistent Volumes | PVC usage, capacity |
| Namespace Resources | Per-namespace resource consumption |

### Data layer

| Dashboard | What it shows |
|-----------|---------------|
| MySQL Overview | Connections, queries/sec, InnoDB metrics, wsrep replication |
| PXC/Galera Cluster | Cluster size, flow control, replication health |
| Kafka Overview | Broker request rate, consumer lag, under-replicated partitions |
| Redis Overview | Connected clients, memory usage, commands/sec |

### Mojaloop

| Dashboard | What it shows |
|-----------|---------------|
| Transfer Pipeline | End-to-end transfer latency, success/failure rates |
| Account Lookup Service | Party resolution latency, cache hit rate |
| Quoting Service | Quote latency, error rates |
| Node.js Runtime | Event loop lag, heap usage, GC pauses |

## Key metrics to watch

Critical metrics with healthy ranges and alert thresholds:

| Metric | Healthy | Warning | Critical | Dashboard |
|--------|---------|---------|----------|-----------|
| PXC cluster size | 1 (or 3) | N/A | < expected | PXC/Galera |
| Kafka consumer lag | < 1000 | > 5000 | > 50000 | Kafka Overview |
| Transfer success rate | > 99% | < 99% | < 95% | Transfer Pipeline |
| Node memory usage | < 80% | > 80% | > 95% | Node Overview |
| API server latency (p99) | < 1s | > 1s | > 5s | Kube API Server |

## Log queries (Loki)

Use Grafana's Explore tab with the Loki datasource. Common queries:

```logql
# All errors in mojaloop namespace
{namespace="mojaloop"} |= "error" | logfmt

# Specific service logs
{namespace="mojaloop", pod=~"moja-central-ledger.*"}

# Vault agent activity
{namespace="mcm", container="vault-agent"}

# Flux reconciliation errors
{namespace="flux-system"} |= "error"

# Helm controller failures
{namespace="flux-system", pod=~"helm-controller.*"} |= "failed"
```

## Observability configuration

For env clusters, set the Tooling Cluster endpoints in `config.yaml`:

```yaml
observability:
  loki_url: "https://loki.int.<tooling-domain>/loki/api/v1/push"
  mimir_url: "https://thanos.int.<tooling-domain>/api/v1/receive"
```

> **Note:** `mimir_url` is a historical name -- it points to Thanos Receive.

The Tooling Cluster is optional. When these values are omitted, env clusters run without centralized observability -- Grafana still works locally with in-cluster Prometheus data, but logs and long-term metrics storage are not available.

## Retention

All signals: 7 days (168h). See [observability architecture](../architecture/observability.md#retention) for configuration details.

## Known constraints

- ~2h data loss window on Thanos Receive crash (in-memory WAL not yet flushed)
- No Tooling Cluster self-monitoring (Tooling Cluster observability stack does not monitor itself)
- No alerting configured (dashboards are passive; no AlertManager rules ship by default)

For details, see [observability known constraints](../architecture/observability.md#known-constraints).
