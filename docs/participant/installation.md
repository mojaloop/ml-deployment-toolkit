# Installation

[docs](../index.md) / [Participant Guide](index.md) / Installation

**Audiences:** participant (DFSP operator)

Install the DFSP Helm chart, back up the recovery kit, configure DNS, and verify connectivity.

Before you start, make sure you've completed [Prerequisites](prerequisites.md).

## 1. Create the OIDC client-secret Secret

The chart never renders Secrets containing literal OIDC credentials. You create one before installing. By default the chart expects the Secret to be named `<release>-dfsp-auth` with a key `clientSecret` — override via `hub.auth.secretName` / `hub.auth.secretKey` if you use a different convention (e.g. your Secrets operator writes to a different name).

```bash
kubectl create namespace dfsp-201
kubectl -n dfsp-201 create secret generic dfsp-dfsp-auth \
  --from-literal=clientSecret='<secret-from-switch-operator>'
```

(Above assumes `helm install dfsp ...` — release name `dfsp` → default Secret name `dfsp-dfsp-auth`.)

If you manage secrets through an operator (External Secrets, Sealed Secrets, SOPS, etc.), point that operator at this Secret name and key; the chart will pick it up at pod-startup time.

## 2. Write values.yaml

Create a file `my-dfsp-values.yaml` with at least the following:

```yaml
dfsp:
  id: dfsp-201
  fqdn: dfsp-201.yourbank.com
  currencies: [USD]

hub:
  mcmServerEndpoint: https://mcm.switch.example.com/pm4mlapi
  iamProviderUrl:    https://keycloak.switch.example.com
  extapiFqdn:        extapi.switch.example.com
  # hub.auth.clientId defaults to dfsp.id; override only if the switch operator
  # registered a different id in Keycloak.
  # auth:
  #   clientId:   custom-id
  #   secretName: my-custom-secret-name   # defaults to <release>-dfsp-auth
  #   secretKey:  myKey                   # defaults to clientSecret
```

All other values have sensible defaults. See the [chart README](../../dfsp/README.md) for the full values reference.

### Use your own backend instead of the simulator

To connect the SDK adapter to your own core-banking connector instead of the bundled Mojaloop simulator, set:

```yaml
backend:
  useSimulator: false
  endpoint: http://my-cbs.cbs-namespace.svc.cluster.local:8080
```

The sim-backend workloads will not be rendered; the SDK adapter's `BACKEND_ENDPOINT` will point at your connector. See [Prerequisites — core-banking backend](prerequisites.md#on-your-side--core-banking-backend-optional) for what your connector must expose.

### Customising beyond values

The chart is a reference implementation. If you need to change anything not exposed as a value — pod security context, extra environment variables, custom annotations, swapped images, additional sidecars, or specific ingress resources for operator tooling — edit the templates directly in your fork. The values file covers cross-deployment identity (who you are, who the switch is, how to authenticate) and nothing else.

### Accessing operator tools

The chart exposes nothing externally beyond the SDK adapter's `:443` inbound. Operator-facing endpoints (mcm-agent API, SDK metrics, simulator test API) are ClusterIP Services. Reach them via `kubectl port-forward`:

```bash
# mcm-agent status/control API
kubectl -n dfsp-201 port-forward svc/dfsp-dfsp-201-mcm-agent 3000:3000

# SDK adapter Prometheus metrics
kubectl -n dfsp-201 port-forward svc/dfsp-dfsp-201-sdk-internal 4040:4040

# Simulator test API (only when backend.useSimulator: true)
kubectl -n dfsp-201 port-forward svc/dfsp-dfsp-201-sim-backend-test 3003:3003
```

If you want these reachable from outside the cluster, add your cluster's native ingress resource (Ingress / Gateway / Route / mesh) for the specific Services. This is intentionally outside the chart's scope because ingress conventions vary widely between Kubernetes distributions.

## 3. Install the chart

The namespace already exists (you created it in step 1 when provisioning the Secret):

```bash
helm install dfsp /path/to/ml-deployment-toolkit/dfsp \
  -n dfsp-201 \
  -f my-dfsp-values.yaml
```

The chart deploys five workloads:

- `vault` StatefulSet + one-shot init Job
- `mcm-agent` Deployment
- `sdk-scheme-adapter` Deployment + LoadBalancer Service
- `redis` StatefulSet
- `sim-backend` Deployment

Expect ~2 minutes for all workloads to become Ready on first install.

## 4. Wait for Vault init to complete

The `vault-init` Job bootstraps Vault (initialize → unseal → enable K8s auth → create PKI + KV mounts → generate root CA → configure policies). It runs once and writes the recovery kit Secret.

```bash
kubectl -n dfsp-201 wait --for=condition=complete \
  job/dfsp-dfsp-201-vault-init --timeout=5m
```

## 5. Back up the recovery kit

The recovery kit Secret contains the Vault **root token** and **unseal key**. If you lose it and the Vault pod restarts, you cannot unseal Vault and your DFSP cannot rotate certificates. **Back it up immediately.**

```bash
kubectl -n dfsp-201 get secret dfsp-vault-recovery-kit -o yaml \
  > ~/secure-storage/dfsp-201-recovery-kit-$(date +%Y%m%d).yaml
```

Move the file to your organisation's secure offline storage (password manager, HSM, secure print). Then — optionally — delete the in-cluster Secret once you've verified the auto-unseal sidecar is working. (The sidecar reads the Secret on every pod restart, so if you delete the Secret the sidecar can't unseal. Only delete it if you're willing to re-apply it during an incident.)

For most deployments, the safer choice is to keep the Secret in the cluster and rely on your normal cluster-secret hygiene (RBAC, etcd encryption).

## 6. Point DNS at the LoadBalancer

Wait for the `sdk-inbound` Service to receive an external IP:

```bash
kubectl -n dfsp-201 get svc dfsp-dfsp-201-sdk-inbound \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Create a DNS A record for `DFSP_FQDN`:

```
dfsp-201.yourbank.com.    IN    A    <LB IP>
```

(Adjust for your DNS provider's interface.)

Wait for DNS to propagate — typically < 5 minutes if your TTL is short.

## 7. Tell the switch operator

Share your `DFSP_FQDN` with the switch operator. They will register it in the switch as your callback URL. If the switch uses the automated onboarding flow (Vault Agent + TTK Job), enrolment may proceed automatically once your first CSR reaches the MCM API.

## 8. Verify end-to-end

Check that the mcm-agent has completed initial enrolment:

```bash
kubectl -n dfsp-201 logs deploy/dfsp-dfsp-201-mcm-agent | grep -E "(enrolment|state-machine|certificate)"
```

You should see:

- Successful OIDC login
- DFSP root CA generation
- CSR submission and signed cert return
- State machine reaching the `enrolled` state

Once there, the SDK adapter will connect to the mcm-agent WS and start serving FSPIOP traffic on :443.

Seed a test party through the simulator backend:

```bash
kubectl -n dfsp-201 port-forward svc/dfsp-dfsp-201-sim-backend-test 3003:3003 &
curl -X POST http://localhost:3003/repository/parties \
  -H 'content-type: application/json' \
  -d '{
    "displayName": "Alice Test",
    "firstName": "Alice", "lastName": "Test",
    "dateOfBirth": "1990-01-01",
    "idType": "MSISDN",
    "idValue": "20100000100"
  }'
```

If another enrolled DFSP on the same switch runs the same command with different values, the two can exchange transfers via `POST /transfers` on their respective :4001 outbound APIs.

## Uninstall

```bash
helm uninstall dfsp -n dfsp-201

# Helm does not cascade-delete PVCs from StatefulSets.
kubectl delete pvc -n dfsp-201 -l app.kubernetes.io/instance=dfsp

# Optional: remove the namespace.
kubectl delete namespace dfsp-201
```

The recovery kit Secret lives in the namespace and is deleted with it. Make sure your offline backup is in place if you intend to reinstall.

## Upgrade

```bash
helm upgrade dfsp /path/to/ml-deployment-toolkit/dfsp \
  -n dfsp-201 \
  -f my-dfsp-values.yaml
```

Cert rotation is automatic (managed by mcm-agent) and does not require chart upgrades. Chart upgrades apply when you want to change images, replicas, or other configuration.

## Troubleshooting

See [DFSP Integration — Failure modes](../architecture/dfsp-integration.md#failure-modes) for the common ways things can go wrong and how to diagnose them.
