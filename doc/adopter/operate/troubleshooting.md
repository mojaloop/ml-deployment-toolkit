# Troubleshooting

[doc](../../index.md) / [adopter](../index.md) / [operate](../index.md) / Troubleshooting

**Audiences:** adopter (operate)

Symptom-first diagnosis for a running Hub. Deployment-time issues are in [Deploy → Known issues](../deploy/known-issues.md); documented recurring runtime issues are in [Known issues](known-issues.md).

- [First move](#first-move)
- [Flux and reconciliation](#flux-and-reconciliation)
- [Networking](#networking)
- [Certificates](#certificates)
- [Data layer](#data-layer)
- [Vault](#vault)
- [The namespace trap](#the-namespace-trap)

## First move

Whatever the symptom, orient before diving in:

```bash
export KUBECONFIG=$(pwd)/artifacts/<env>/kubernetes/kubeconfig
kubectl get kustomizations -n flux-system
```

If the kubeconfig is missing, expired, or `kubectl` dials `127.0.0.1:1` (the seeded placeholder), restore access first: see [Known issues → Lost or expired cluster access](known-issues.md#lost-or-expired-cluster-access--kubeconfig-and-talosconfig-talos).

If a Kustomization is not Ready, that is almost always the root — fix it before chasing application symptoms, and start from the **earliest** failing one in the chain, since later failures are usually consequences.

## Flux and reconciliation

**A Kustomization stuck on "dependency not ready."** An upstream failed and blocked everything behind it. Find the earliest failure and inspect it:

```bash
kubectl get kustomizations -n flux-system
kubectl describe kustomization <earliest-failing> -n flux-system
```

The chain is `platform` → `dns` → `platform-config` → vendor → role layers.

**A HelmRelease stuck in a failed state.** Read its events, then force a retry:

```bash
kubectl describe helmrelease <name> -n flux-system
flux suspend helmrelease <name> -n flux-system
flux resume helmrelease <name> -n flux-system
```

Suspend/resume is the standard remedy for a HelmRelease that failed on a transient condition — a database that was not ready yet, most often.

**The artifact is not updating.** Check the source:

```bash
kubectl get ocirepository -n flux-system
flux reconcile source oci ml-gitops
```

## Networking

**A Gateway or the FSPIOP service has no address.** On self-managed clusters, LB-IPAM assigns from the configured pool:

```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl logs -n cilium -l k8s-app=cilium --tail=20 | grep -i ipam
```

Usually a pool address overlaps DHCP, or a pool is missing. Remember the counts: a Hub needs **four** single-address pools (`gw-int`, `gw-ext`, `gw-extapi`, `gw-intapi`), a Tooling Cluster two — and a Service that matches no pool stays Pending ([ADR-018](../../architecture/decisions/018-per-gateway-lb-pools.md)).

**DNS records are not being created.** `external-dns` should reconcile them:

```bash
kubectl logs -n external-dns deploy/external-dns-external-dns
kubectl get httproute -A
```

Do not create records by hand — that causes ownership conflicts. If records are missing, it is credentials or an unattached HTTPRoute, not something to fix manually in the DNS console.

## Certificates

**An HTTPS endpoint has a bad certificate.** Work from the challenge outward:

```bash
kubectl get certificates -A
kubectl get certificaterequests -A
kubectl get challenges -A
kubectl get clusterissuer
```

Most failures are DNS-01: the zone is not delegated, credentials are wrong, or propagation is still in flight (allow a few minutes) — the [deploy pre-check](../deploy/deployment.md#pre-deploy-checks) confirms delegation for exactly this reason. The CA's rate limit — too many certificates for one domain too quickly — is the other common cause.

The FSPIOP endpoint certificate is the exception: it comes from Vault, not the ACME CA, so a problem there is a Vault issue, not an ACME one. See [Participant mTLS](../../architecture/participant-mtls.md).

## Data layer

**Everything is in the `data` namespace.** Not `mojaloop`.

**MySQL is not reaching `ready`:**

```bash
kubectl get pxc mojaloop-db -n data -o jsonpath='{.status.state}'
kubectl logs mojaloop-db-pxc-0 -n data -c pxc
kubectl get pvc -n data -l app.kubernetes.io/instance=mojaloop-db
```

Usually memory (PXC needs a substantial InnoDB buffer pool), an unbound PVC, or Galera state transfer blocked between pods. Check `kubectl top nodes` for capacity.

**Kafka brokers not starting:**

```bash
kubectl get pods -n data -l strimzi.io/kind=Kafka
kubectl get pvc -n data -l strimzi.io/kind=Kafka
kubectl logs -n hub-system deploy/strimzi-cluster-operator --tail=50
```

Note the operator is in `hub-system`, not `data`. KRaft needs a majority of brokers up to form a quorum, so a single stuck broker can block the cluster.

## Vault

**Vault is sealed after a restart.** It should auto-unseal — the operator holds the keys and re-applies them:

```bash
kubectl get pods -n vault
kubectl logs -n hub-system deploy/hub-system-vault-operator        # on a Hub
kubectl logs -n tooling-system deploy/tooling-system-vault-operator # on a Tooling Cluster
```

If it stays sealed, the operator is the place to look, not Vault itself. The unseal keys live in the `vault-unseal-keys` Secret in the `vault` namespace; auto-unseal reads them on restart. See [Disaster recovery → What the adopter must keep](../recover/disaster-recovery.md#what-the-adopter-must-keep) for why that Secret is also the adopter's responsibility to back up.

## The namespace trap

More time is lost to this than to any real fault. Kubernetes returns an empty list for the wrong namespace — which looks exactly like a healthy empty result.

| Looking for | Namespace |
|-------------|-----------|
| MySQL, Kafka, MongoDB, Redis | `data` |
| Database operators, the Vault operator (Hub) | `hub-system` |
| Kratos, Hydra, Keto, Oathkeeper | `ory` |
| MCM, its Vault Agent | `mcm` |
| Finance Portal (shell, UIs, reporting APIs) | `finance-portal` |
| Mojaloop pods, the FSPIOP Envoy | `mojaloop` |
| Mojaloop / MCM / Finance Portal HelmReleases | `flux-system` |
| Gateways | `platform-system` |
| Vault itself, its unseal-keys Secret | `vault` |
| Cilium agents | `cilium` |
| external-dns | `external-dns` |
| cert-manager, its challenges | `cert-manager` |
| Alloy, kube-state-metrics, node-exporter | `observability` |

When a `get` unexpectedly returns nothing, confirm the namespace before concluding the resource is missing.
