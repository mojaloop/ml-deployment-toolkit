# 011 — DNS-01 challenges for ACME TLS over HTTP-01

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 011 — DNS-01 challenges for ACME TLS over HTTP-01

**Date:** 2026-03-31
**Status:** accepted — amended by [016](016-generic-acme-ca.md)
**Audiences:** architect, platform developer, network engineer

> **Amended.** [ADR-016](016-generic-acme-ca.md) generalized the certificate authority: the CA is selected by directory URL (`cert.server`, required), the issuer is named `acme-prod` in `clusterissuer.yaml`, and "Let's Encrypt" below reads as "the configured ACME CA". The DNS-01 decision itself is unchanged and still holds on all three DNS providers.

## Context

TLS certificates are provisioned automatically via cert-manager and Let's Encrypt (ACME protocol). ACME supports two validation methods: HTTP-01 (Let's Encrypt makes an HTTP request to the domain) and DNS-01 (Let's Encrypt checks for a DNS TXT record). On-prem Mojaloop deployments use Cilium LB-IPAM with private IP addresses (RFC 1918) that are not reachable from the public internet. Let's Encrypt cannot reach these IPs for HTTP-01 validation.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| HTTP-01 | Simple setup, no DNS API access needed | Requires public IP reachable by Let's Encrypt; impossible on private on-prem networks; does not support wildcard certificates |
| DNS-01 | Works with private IPs (validates via DNS TXT records), supports wildcard certificates, works on all providers | Requires DNS provider API credentials, slightly slower validation (DNS propagation) |

## Decision

DNS-01 challenges for all ACME certificate issuance, on all providers (on-prem and cloud). This provides a consistent TLS provisioning model regardless of whether LoadBalancer IPs are public or private. DNS provider integration is configured per-environment via the `gitops/dns/{provider}/` kustomization, which deploys the appropriate cert-manager `ClusterIssuer` with DNS-01 solver configuration.

Supported DNS providers: DigitalOcean, Cloudflare, Route53. The DNS provider is an independent dimension from the infrastructure provider (e.g., Proxmox + Cloudflare, AWS + DigitalOcean are valid combinations).

## Consequences

- **Works on private networks.** On-prem deployments with RFC 1918 LB IPs get valid Let's Encrypt certificates without exposing any service to the public internet.
- **Wildcard certificates enabled.** The shared Gateways use wildcard certs (`*.int.${domain}`, `*.ext.${domain}`), which are only possible with DNS-01. This eliminates per-HTTPRoute certificate provisioning.
- **DNS provider API credentials required.** Each environment needs API credentials for its DNS provider (e.g., `DIGITALOCEAN_TOKEN`, `CLOUDFLARE_API_TOKEN`, `AWS_ACCESS_KEY_ID`). These flow from `.env` through Terraform to a Kubernetes Secret.
- **Consistent across providers.** Cloud deployments (which could use HTTP-01) use DNS-01 anyway, avoiding provider-specific TLS configuration logic.
- **DNS propagation delay.** Certificate issuance depends on DNS TXT record propagation, which can add 30-120 seconds compared to HTTP-01. Acceptable for certificate lifecycle operations.
