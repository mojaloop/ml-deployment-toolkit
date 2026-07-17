# Prerequisites

[docs](../index.md) / [Participant Guide](index.md) / Prerequisites

**Audiences:** participant (DFSP operator)

What you need in place before installing the DFSP chart.

## From the switch operator

The switch operator provisions your DFSP in the switch and issues a credentials bundle out-of-band (encrypted email, secure share). Expect the following values:

| Value | Example | Purpose |
|---|---|---|
| `DFSP_ID` | `dfsp-201` | Your participant id in the switch's central-ledger. Also used as the OIDC client id unless the switch operator registered a different one. |
| OIDC client id (if different) | `dfsp-201-client` | Only needed if the switch operator registered a non-matching id in Keycloak. Set via `hub.auth.clientId`. |
| OIDC client secret | `<32-char secret>` | Keycloak `hub-operators` realm client secret. You place it in a Kubernetes Secret (see [Installation](installation.md)); the chart references it by name. |
| `MCM_SERVER_ENDPOINT` | `https://mcm.switch.example.com/pm4mlapi` | MCM REST API base URL |
| `HUB_IAM_PROVIDER_URL` | `https://keycloak.switch.example.com` | Keycloak base URL |
| `HUB_EXTAPI_FQDN` | `extapi.switch.example.com` | FSPIOP mTLS endpoint (no protocol, no port — port is always 443) |

If you don't have these yet, contact the switch operator before proceeding.

## On your side — Kubernetes

| Requirement | Notes |
|---|---|
| Kubernetes cluster ≥ 1.28 | Any distribution, any CNI — EKS, GKE, AKS, OpenShift, k3s, Talos, kubeadm, etc. |
| LoadBalancer provisioning | One LB IP is needed for the SDK adapter's inbound Service. Cloud LB controller or an in-cluster implementation like MetalLB / Cilium LB-IPAM. |
| PersistentVolume support | One PVC (~1 GiB) is required for Vault |
| `helm` ≥ 3.12 | Client-side |
| `kubectl` ≥ 1.28 | For port-forwarding and post-install verification |
| Egress to the switch's FQDNs on :443 | `mcm`, `keycloak`, `extapi` — verify from inside the cluster: `kubectl run test --rm -it --image=curlimages/curl -- curl -sI https://mcm.switch.example.com/health` |

The chart does not require Gateway API, a specific CNI, a specific storage class, or any controller beyond a LoadBalancer implementation. It's a reference implementation — if your cluster has conventions around ingress, observability, or secrets management, edit the templates to match.

### On your side — core-banking backend (optional)

If you will run with your own core-banking connector instead of the bundled simulator, the connector must:

- Expose the [Mojaloop SDK backend API](https://github.com/mojaloop/sdk-scheme-adapter/tree/master/modules/api-svc/src/BackendAPI) on HTTP — no TLS, no auth (it's an internal pod-to-pod Service).
- Be deployed on the same Kubernetes cluster OR reachable via a stable Service URL.
- Have a resolvable Service name like `http://my-cbs.cbs-namespace.svc.cluster.local:8080` that you will pass to the chart as `backend.endpoint`.

If you don't have a backend yet, install with the default `backend.useSimulator: true` — the chart deploys the Mojaloop simulator as a functional stand-in.

## On your side — DNS

You need **one public FQDN** under your control that will point at the DFSP chart's inbound LoadBalancer. Call this `DFSP_FQDN`. Examples:

- `dfsp-201.yourbank.com`
- `mojaloop.yourbank.com`

Requirements:

- **Resolvable from the switch's egress network.** The switch initiates FSPIOP callbacks to you, so its Kubernetes nodes must be able to resolve this name.
- **Not wildcarded against a name you don't control.** The cert chain depends on the FQDN matching exactly.
- **You control the DNS zone.** You'll create an A record pointing to the LoadBalancer IP after `helm install`.

The certificate for `DFSP_FQDN` is not something you provision — the MCM agent enrols with the switch's Mojaloop CA and obtains a signed server cert as part of the standard flow. You do not need Let's Encrypt, a public CA, or any manual cert purchase. The DNS record is the only DNS task on your side.

## On your side — network

| Item | Requirement |
|---|---|
| Inbound TCP :443 to `DFSP_FQDN` | Must be reachable from the switch's public egress. If you're behind NAT/firewall, poke a hole. |
| Outbound TCP :443 to the switch's FQDNs | `mcm`, `keycloak`, `extapi`. If you have strict egress filtering, allow-list them. |
| No proxy for switch traffic | If your cluster routes egress through a corporate HTTP(S) proxy, configure the mcm-agent's `HTTP_PROXY` env via `mcmAgent.extraEnv` (or exclude switch FQDNs from the proxy). |

## Ready?

Once you have everything above, proceed to [Installation](installation.md).
