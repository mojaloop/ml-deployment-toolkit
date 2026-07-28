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

If the kubeconfig is missing — or `kubectl` dials `127.0.0.1:1`, meaning it is the seeded placeholder — regenerate it first: see [Known issues → Lost or placeholder kubeconfig](known-issues.md#lost-or-placeholder-kubeconfig).

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
kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -i ipam
```

Usually the pool overlaps DHCP, or it is exhausted. Remember the counts: a Hub needs **three** addresses (`gw-int`, `gw-ext`, `extapi`), a Tooling Cluster two. A pool sized for two starves the third.

**DNS records are not being created.** `external-dns` should reconcile them:

```bash
kubectl logs -n external-dns deploy/external-dns
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

Most failures are DNS-01: the zone is not delegated, credentials are wrong, or propagation is still in flight (allow a few minutes). This is why the [deploy pre-check](../deploy/deployment.md#pre-deploy-checks) confirms delegation first. A Let's Encrypt rate limit — too many certificates for one domain too quickly — is the other common cause.

The FSPIOP endpoint certificate is the exception: it comes from Vault, not Let's Encrypt, so a problem there is a Vault issue, not an ACME one. See [Participant mTLS](../../architecture/participant-mtls.md).

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
kubectl logs -n env-system deploy/strimzi-cluster-operator --tail=50
```

Note the operator is in `env-system`, not `data`. KRaft needs a majority of brokers up to form a quorum, so a single stuck broker can block the cluster.

## Vault

**Vault is sealed after a restart.** It should auto-unseal — the operator holds the keys and re-applies them:

```bash
kubectl get pods -n vault
kubectl logs -n <cc-system|env-system> deploy/vault-operator
```

If it stays sealed, the operator is the place to look, not Vault itself. The unseal keys live in a Secret in the `vault` namespace; auto-unseal reads them on restart. See [Data layer → What the adopter must keep](../recover/disaster-recovery.md#what-the-adopter-must-keep) for why that Secret is also the adopter's responsibility to back up.

## The namespace trap

More time is lost to this than to any real fault. Kubernetes returns an empty list for the wrong namespace — which looks exactly like a healthy empty result.

| Looking for | Namespace |
|-------------|-----------|
| MySQL, Kafka, MongoDB, Redis | `data` |
| Database operators | `env-system` |
| Kratos, Hydra, Keto, Oathkeeper | `ory` |
| MCM, its Vault Agent | `mcm` |
| Mojaloop pods, Finance Portal, the FSPIOP Envoy | `mojaloop` |
| Mojaloop / MCM HelmReleases | `flux-system` |
| Gateways | `platform-system` |

When a `get` unexpectedly returns nothing, confirm the namespace before concluding the resource is missing.
