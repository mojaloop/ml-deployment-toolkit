# Troubleshooting

[docs](../index.md) / [operations](index.md) / Troubleshooting

**Audiences:** adopter (operate)

Symptom-based diagnosis and resolution for ML Deployment Toolkit runtime issues. For architecture context, see [system overview](../architecture/system-overview.md) and [networking](../architecture/networking.md).

---

## Flux and GitOps issues

### Kustomization stuck on "dependency not ready"

**Symptoms:**
`kubectl get kustomizations -n flux-system` shows one or more kustomizations waiting on a dependency that never becomes ready.

**Diagnosis:**

1. List all kustomizations to find the first failure in the dependency chain:
   ```bash
   kubectl get kustomizations -n flux-system
   ```
2. Inspect events on the first failing kustomization:
   ```bash
   kubectl describe kustomization <name> -n flux-system
   ```

**Common causes:**
- Missing or incorrect DNS credentials in `cluster-secrets`
- cert-manager not ready (blocks `platform-config` and everything downstream)
- Vendor kustomization failed (e.g., Cilium HelmRelease error on Talos clusters)

**Resolution:**
Fix the root cause on the first failing kustomization. Downstream kustomizations will reconcile automatically once their dependency becomes ready.

---

### HelmRelease in "Failed" state

**Symptoms:**
`flux get helmreleases -A` shows a release with status `False` and a failure message.

**Diagnosis:**

```bash
# Check release status across all namespaces
flux get helmreleases -A

# Check Helm history for the specific release
helm history <name> -n <namespace>

# Check Helm controller logs for errors
kubectl logs -n flux-system deploy/helm-controller --tail=50
```

**Resolution:**
Suspend and resume the HelmRelease to trigger a retry:

```bash
flux suspend helmrelease <name> -n flux-system
flux resume helmrelease <name> -n flux-system
```

If the failure persists, check the Helm history for the specific error and fix the underlying issue (missing secret, invalid values, resource conflict).

---

### OCIRepository not reconciling

**Symptoms:**
`kubectl get ocirepositories -n flux-system` shows `Ready: False` or the revision is stale.

**Diagnosis:**

```bash
# Check OCIRepository status
kubectl get ocirepositories -n flux-system -o yaml

# Verify credentials exist
kubectl get secret oci-credentials -n flux-system

# Test OCI access manually
flux pull artifact <url> --output /tmp/test
```

**Common causes:**
- Wrong OCI URL in `config.yaml`
- Expired or incorrect OCI credentials in `.env`
- Network issue reaching the registry (firewall, DNS resolution)

**Resolution:**
Verify `oci.repo.url`, `OCI_REPO_USERNAME`, and `OCI_REPO_PASSWORD` in your environment config, then re-apply:

```bash
make plan-apply ENV=<env>
```

---

## Networking issues

### Gateway not getting a LoadBalancer IP (on-prem)

**Symptoms:**
Gateway or Service of type `LoadBalancer` stays in `Pending` state with no external IP assigned.

**Diagnosis:**

```bash
# Check LB-IPAM pool
kubectl get ciliumloadbalancerippool

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy

# Check Cilium agent logs for LB-IPAM errors
kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -i ipam
```

**Common causes:**
- IP range in `CiliumLoadBalancerIPPool` conflicts with DHCP range
- IP range exhausted (all IPs in the pool are allocated)
- L2 announcement policy missing or misconfigured
- Cilium agent not running on the node that should announce

**Resolution:**
Verify the IP range in `app.lb_ipam_range` (in `config.yaml`) does not overlap with your network's DHCP range and has enough IPs for all 3 LB services (gw-int, gw-ext, gw-extapi).

---

### DNS records not created

**Symptoms:**
HTTPRoutes are deployed and Gateways have IPs, but DNS records (A records) are not created in the DNS provider.

**Diagnosis:**

```bash
# Check external-dns logs for errors
kubectl logs -n platform-system deploy/external-dns

# Verify DNS credentials are present
kubectl get secret cluster-secrets -n flux-system -o jsonpath='{.data}' | jq 'keys'

# Check HTTPRoute status
kubectl get httproute -A
```

**Common causes:**
- DNS credentials missing or incorrect in `cluster-secrets`
- external-dns not watching the correct sources (should include `gateway-httproute`)
- HTTPRoute not attached to a Gateway (check `.status.parents`)

**Resolution:**
Verify DNS credentials in `config/environments/<env>/.env` and re-apply. Check that external-dns is configured with `--source=gateway-httproute`.

---

### TLS certificate not provisioning

**Symptoms:**
HTTPS endpoints return certificate errors. `kubectl get certificates -A` shows certificates not in `Ready` state.

**Diagnosis:**

```bash
# Check certificate status
kubectl get certificates -A

# Check certificate requests
kubectl get certificaterequests -A

# Check ClusterIssuer status
kubectl get clusterissuer -o yaml

# Check active challenges
kubectl get challenges -A
```

**Common causes:**
- DNS-01 challenge failing (DNS credentials wrong, DNS propagation delay)
- ClusterIssuer not ready (missing DNS solver secret)
- Let's Encrypt rate limit hit (too many certificates for the same domain in a short period)

**Resolution:**
Start with the challenge status. If the challenge shows a DNS propagation error, verify DNS credentials and wait for propagation (up to 5 minutes). If the ClusterIssuer is not ready, check the DNS solver secret referenced by the issuer.

---

## Data layer issues

### PXC cluster not reaching "ready" state

**Symptoms:**
`kubectl get pxc mojaloop-db -n mojaloop -o jsonpath='{.status.state}'` does not report `ready`. PXC pods may be in CrashLoopBackOff or Init state.

**Diagnosis:**

```bash
# Check PXC status
kubectl get pxc mojaloop-db -n mojaloop -o yaml

# Check pod logs
kubectl logs mojaloop-db-pxc-0 -n mojaloop -c pxc

# Check PVC binding
kubectl get pvc -n mojaloop -l app.kubernetes.io/instance=mojaloop-db
```

**Common causes:**
- Insufficient memory for InnoDB buffer pool (PXC requires significant memory)
- PVC not bound (storage class unavailable or insufficient disk)
- Galera SST failing (network policy blocking inter-pod communication)

**Resolution:**
Check node resources with `kubectl top nodes`. For memory issues, ensure nodes have enough capacity for PXC pods. For storage issues, verify the storage class exists and PVCs can bind.

---

### Kafka broker not starting

**Symptoms:**
Kafka pods are not running. `kubectl get pods -n mojaloop -l strimzi.io/kind=Kafka` shows pods in Pending or CrashLoopBackOff.

**Diagnosis:**

```bash
# Check Kafka pods
kubectl get pods -n mojaloop -l strimzi.io/kind=Kafka

# Check PVCs (KRaft requires persistent storage)
kubectl get pvc -n mojaloop -l strimzi.io/kind=Kafka

# Check Strimzi operator logs
kubectl logs -n mojaloop deploy/strimzi-cluster-operator --tail=50
```

**Common causes:**
- PVCs not bound (storage class missing or disk unavailable)
- Insufficient memory for JVM heap
- KRaft metadata quorum cannot form (requires majority of brokers)

**Resolution:**
Ensure PVCs are bound and nodes have sufficient resources. For KRaft quorum issues, all broker pods must be running -- check each pod individually.

---

## Vault issues

### Vault sealed after pod restart

**Symptoms:**
Vault pod is running but returns `503 Service Unavailable`. `kubectl exec` into the pod shows Vault is sealed.

**Diagnosis:**

```bash
# Check vault-operator logs
kubectl logs -n vault-system deploy/vault-operator

# Verify unseal secret exists
kubectl get secret vault-unseal-keys -n vault

# Check Vault pod status
kubectl get pods -n vault -l app.kubernetes.io/name=vault
```

**Resolution:**
The bank-vaults operator should auto-unseal Vault using the K8s Secret. If auto-unseal is not working:

1. Check operator logs for errors
2. Verify the unseal secret exists and has data
3. Restart the operator: `kubectl rollout restart deploy/vault-operator -n vault-system`

---

## Useful commands

```bash
# Flux debugging
flux get all -n flux-system
flux logs --level=error
kubectl get events -n flux-system --sort-by='.lastTimestamp'

# Force re-reconcile from OCI source
flux reconcile source oci ml-gitops -n flux-system

# Terraform state
make show ENV=<env>
make list ENV=<env>

# Talos (on-prem)
export TALOSCONFIG=$(pwd)/artifacts/<env>/talos-config/talosconfig
talosctl health --nodes <vip>
talosctl dmesg --nodes <vip>
talosctl services --nodes <vip>

# General Kubernetes debugging
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type=Warning
kubectl top nodes
kubectl top pods -A --sort-by=memory
```
