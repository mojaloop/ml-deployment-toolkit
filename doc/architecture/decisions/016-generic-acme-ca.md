# 016 — Certificate authority as configuration, not a provider enum

[doc](../../index.md) / [architecture](../index.md) / [decisions](./) / 016 — Certificate authority as configuration

**Date:** 2026-08-05
**Status:** accepted
**Audiences:** architect, platform developer, adopter

## Context

TLS certificates are issued through cert-manager over ACME with DNS-01 challenges ([ADR-011](011-dns01-over-http01.md)). Until now the issuer manifest was Let's Encrypt-shaped throughout: named `letsencrypt-prod`, filed as `letsencrypt.yaml`, with a hardcoded staging companion. `cert.server` was templated, so the directory URL could be changed, but nothing could emit `externalAccountBinding` — the External Account Binding that ties an ACME account to a pre-existing account at the CA.

That gap was decisive rather than cosmetic. Let's Encrypt is the only public CA that lets an account register anonymously. Google Trust Services, ZeroSSL, SSL.com and every commercial CA require EAB, so in practice the only reachable alternatives were the Let's Encrypt staging endpoint and a self-hosted ACME server. An adopter with a CA contract, a regional trust requirement, or simply a need for a second source could not use it.

EAB cannot be handled by substitution. Flux `postBuild` substitution is string replacement over rendered YAML — it can fill a scalar but cannot include or omit a block, and the block must be *absent* for Let's Encrypt. An empty `keyID` makes cert-manager attempt EAB registration, which the CA rejects with `Invalid MAC on JWS request`.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| **Provider enum + directory per CA** (mirroring `gitops/dns/<provider>/`) | Consistent with the established DNS pattern; each CA self-contained | The issuer fuses two axes — CA and DNS solver — in one resource, so path selection yields N×M directories. Every new CA is a code change, which is the outcome being designed away |
| **Passthrough map** — `cert.acme` merged wholesale into `spec.acme` | Maximum future-proofing; picks up `profile`, `preferredChain`, anything cert-manager adds | No schema validation; the secret half still needs a fixed ref, so the model is not uniform. Neither Traefik nor Caddy chose this despite years of multi-CA pressure |
| **URL + optional EAB, conditional block via Terraform-generated patch** | Two knobs cover every ACME CA; no per-provider code; matches Traefik and Caddy | Requires a one-time conditional in Terraform; `profile` and `preferredChain` need an additive field if ever wanted |
| Keep Let's Encrypt only | No work | Leaves adopters with one CA and no second source |

## Decision

The certificate authority is selected by **directory URL alone** — `cert.server` in `config.yaml`. There is no CA enum. The URL *is* the provider identity, which is how Traefik (`caServer`) and Caddy (`acme_ca`) both model it after years of supporting multiple CAs.

External Account Binding is a second, optional dimension supplied through `.env` as `ACME_EAB_KEY_ID` and `ACME_EAB_HMAC_ENCODED`. Its schema is fixed by RFC 8555 at keyID plus HMAC key and is identical for every CA; only the values differ. **Credential presence is the switch** — there is no toggle in `config.yaml`, matching how OCI registry credentials already work.

The conditional block is emitted as a Flux Kustomization patch generated in `flux-config`, reusing the mechanism that already exists for `backup_disabled_patches`. Terraform performs the conditional; kustomize performs the merge.

`cert.server` is **required**, not defaulted. A silent fallback to Let's Encrypt would leave the issuing authority invisible in the config — the same implicitness this record exists to remove — so every environment states its CA outright.

Supporting changes: the issuer is renamed `letsencrypt-prod` → `acme-prod` and its file `letsencrypt.yaml` → `clusterissuer.yaml`; the unused staging issuer is deleted; the ACME account-key Secret is named after a hash of the directory URL; `cert.provider` is removed from the schema, having never been read.

## Consequences

- **Any ACME CA is now a config edit.** Adding Google Trust Services or ZeroSSL means one URL and two `.env` values. No manifest, no module, no schema change.
- **This is a breaking config change.** `cert.provider` is rejected where it was previously accepted, `cert.server` is now mandatory, and `cert` is required at the top level. Every existing `config.yaml` needs both edits before `make validate` passes. The schema still declares `version: 1`; if the adopter base grows beyond the point where a changelog line suffices, this is the change that should have bumped it.
- **One patch covers all three DNS providers.** Kustomize patches target by kind and name rather than path, so the issuer is matched in whichever `gitops/dns/<provider>/` directory it came from. The existing triplication does not grow.
- **The issuer name is a static literal and cannot be adopter-configurable.** Flux applies `spec.patches` during kustomize build and substitution afterwards, so a patch cannot target a name that is still a `${...}` placeholder at patch time.
- **Renaming the issuer re-issues certificates once per existing cluster.** The Gateway annotations move from `letsencrypt-prod` to `acme-prod`, so cert-manager provisions fresh wildcards. Automatic, but not free — expect brief overlap on upgrade.
- **The account key is named after the directory URL.** Reusing one name across CAs makes cert-manager keep the cached account and silently ignore the new server and EAB. Hashing the URL turns that silent failure into correct re-registration, at the cost of leaving an orphaned Secret behind after a CA switch.
- **The EAB Secret is always rendered, even unused.** Kustomize patches modify existing resources but cannot add new ones, so `acme-eab-credentials` must exist in the base. It is inert and empty on Let's Encrypt.
- **Half-configured EAB fails at plan, not at `make validate`.** The credentials live in `.env`, which the `config.yaml` JSON Schema never sees, so the check is a Terraform precondition in `flux-config`. `make validate` stays schema-only and will not catch it.
- **`profile` and `preferredChain` are not exposed.** Both are real cert-manager ACME fields with plausible uses. Neither is modelled, on the evidence that Traefik and Caddy did not need them either; adding one later is additive.
- **Free tiers are not equivalent.** SSL.com's free DV covers a single domain plus `www` and cannot serve the `*.int` / `*.ext` wildcards the shared Gateways depend on. ZeroSSL's free ACME allowance is ambiguous in its own documentation. Google Trust Services is the alternative that has been verified to fit.
