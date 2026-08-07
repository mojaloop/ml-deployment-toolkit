# 017 — Capability endpoints stated, not derived

[doc](../../index.md) / [architecture](../index.md) / [decisions](index.md) / 017 — Capability endpoints stated

**Date:** 2026-08-05
**Status:** accepted
**Audiences:** architect, platform developer, adopter (deploy)

Supersedes the tooling-preset clause of [ADR-015](015-two-stack-capability-config.md); everything else in that record stands. Extends [ADR-016](016-generic-acme-ca.md) from `cert` to the three remaining capabilities that still carried a provider enum.

## Context

[ADR-016](016-generic-acme-ca.md) removed `cert.provider` and made the ACME directory URL the CA's identity, on the reasoning that a defaulted authority is an invisible one: "a silent fallback to Let's Encrypt would leave the issuing authority invisible in the config — the same implicitness this record exists to remove."

Three capabilities were left untouched by it, each still selected by an enum: `registry` (`tooling` / `harbor` / `none`), `object_storage` (`tooling` / `s3` / `none`) and `observability` (`tooling` / `urls` / `none`). Reviewing them against ADR-016's own principle exposed four problems.

**The enum did not name a provider.** Nothing in the toolkit branches on `s3` versus `harbor` versus `urls`. All three backup consumers — the PSMDB `PerconaServerMongoDB`, the PXC `PerconaXtraDBCluster`, and the Vault snapshot CronJob's `aws s3 cp` — are plain SigV4 S3 clients reading one endpoint. The value `s3` selected against an empty set; it meant only "not `tooling`, and not off". The ecosystem convention is consistent on this point: a discriminator earns its place when the nested schema differs per value (Thanos `type:`, Velero `provider:`, Percona's own `s3`/`gcs`/`azure`/`minio` blocks), and is absent when only one protocol is ever spoken (restic's `s3:` URL, Longhorn's `backupTarget`, CloudNativePG's `destinationPath` scheme).

**The preset it existed to trigger was never used.** `provider: tooling` derived five endpoints from `tooling.domain`. Across all seven tracked and untracked environment configs, not one set `tooling.domain`, and not one used `provider: tooling` on any capability. Every environment already transcribed its URLs in full. The mechanism ADR-015 introduced to prevent transcription had, in practice, prevented nothing.

**Values arrived that nobody had stated.** `object_storage.bucket` defaulted to `backups` and `region` to `us-east-1`; `cert.email` defaulted to `admin@<dns.domain>`. Each is a silent, late failure: backups written to a bucket nobody named, a SigV4 signature computed for the wrong region, and CA expiry notices delivered to a mailbox the toolkit invented. None of the three surfaces at plan time.

**Blank values were load-bearing in two different directions.** `registry_active` was `registry_url != ""`, so a URL typo'd to empty silently disabled the pull-through cache rather than failing. Meanwhile `object_storage` genuinely needed a structural off switch, because PSMDB >=1.22 refuses to mark a cluster ready — and refuses to create app users — while PBM cannot reach its storage. The same emptiness meant "off" in one capability and "misconfigured" in another.

## Alternatives considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the enum, rename `s3`/`harbor`/`urls` to `explicit` | One-word diff; keeps the preset | Cosmetic. The tautological value becomes an honest tautology, and the three hidden defaults survive untouched |
| Single field carries the identity — `endpoint: "tooling"` or a URL, mirroring `cert.server` | Most consistent with ADR-016; keeps the preset | A magic string inside a URL field is *less* discoverable than an enum: JSON Schema renders `enum` into editor completion and error text, a reserved URL value renders as nothing |
| Infer off from an absent block | Shortest configs | Inverts the safest failure. An omitted `object_storage` would silently disable backups — the one capability where off must be deliberate |
| **`enabled` boolean plus stated endpoints, no derivation** (chosen) | Every endpoint the cluster uses is visible in the file; off is explicit in all three; missing values fail at plan | Five URLs to write per Hub instead of one domain; a real regression in typing, accepted deliberately |

## Decision

**Endpoints are stated, never derived.** `tooling.domain` and the whole `tooling:` top-level block are removed, along with the `provider` enum on `registry`, `object_storage` and `observability`. Each takes `enabled: true|false` and, when enabled, its endpoint fields outright. What the adopter reads in `config.yaml` is what the cluster is pointed at, with no second file to consult and no derivation rule to know.

**`enabled` is required and explicit, and so are the three blocks.** `registry`, `object_storage` and `observability` join the top-level `required` list, and `enabled` is required within each. A cluster that ships no telemetry says `observability: {enabled: false}` rather than omitting the section — off is a decision the config records, not an absence the reader has to notice.

**No capability value is defaulted.** `object_storage.bucket` and `object_storage.region` are required when enabled; `cert.email` is required unconditionally, amending ADR-016, which made only `cert.server` mandatory.

**Missing values fail at plan, not at reconcile.** JSON Schema cannot express "required when `enabled` is true" — and `tools/validate.py` implements a deliberately fixed keyword subset that rejects `if`/`then` as a schema error rather than ignoring it — so the conditional requirements are Terraform preconditions in `config-loader`, following ADR-015's own rule that cross-field constraints live there. Four preconditions now cover `cert.email`, and each of the three capabilities being enabled with an incomplete endpoint set.

**`robots` and `buckets` are unaffected.** Both are Tooling-Cluster *provisioning* lists gated on `cluster.role`, not on whether this cluster consumes the capability. A Tooling Cluster sets `registry.enabled: false` while still declaring the robots it serves.

## Consequences

- **A Hub backed by a Tooling Cluster writes five URLs.** This is the cost ADR-015 set out to avoid, accepted here on the evidence that its remedy went unused for the life of the record while the hidden defaults caused real, silent misconfiguration. Repointing a Hub at a different Tooling Cluster is now five edits in one file rather than one.
- **The drift ADR-015 warned about is now caught earlier than before, not later.** Its concern was typos failing late in reconciliation. `registry` and `observability` previously had no completeness check at all — a blank registry URL silently disabled the cache. Every capability now fails at plan when enabled without a full endpoint set. What still cannot be caught is a well-formed URL pointing at the wrong host; no schema or precondition detects that, and derivation was the only thing that ever could.
- **This is a breaking config change**, in the same shape as ADR-016 and with no compatibility layer, per ADR-015's precedent. `provider` is rejected wherever it appears, `tooling` is rejected at the top level, `enabled` is mandatory in three sections that are themselves now mandatory, and `cert.email` is mandatory. The schema still declares `version: 1`.
- **The `.env` conditions are restated in terms of `enabled`.** `OCI_PROXY_*` is needed when `registry.enabled` is true; `BACKUP_S3_*` when `object_storage.enabled` is true.
- **`object_storage.enabled: false` remains structural, not cosmetic.** It still drives `backup_disabled_patches`, which strip the PSMDB backup block, the PXC schedule and PITR, and suspend the Vault snapshot CronJob. Because those patches remove the backup configuration wholesale, the now-blank `bucket` and `region` never reach a live resource.
- **Turning backups on later still restarts the mongod pods**, since PBM sidecars are added. Unchanged by this record, and worth stating wherever `enabled` is documented.
- **Adding a second endpoint per capability stays additive.** Nothing in the new shape assumes one URL per capability; `observability` already carries three.
- **The S3 compatibility knobs remain unexposed.** `forcePathStyle`, `insecureSkipTLSVerify` / `verifyTLS`, and PSMDB's `caBundle` and `minio` storage type all exist in the operator CRD versions currently pinned, and none is plumbed through. Any S3-compatible endpoint works so long as it speaks SigV4 with a static keypair and presents a publicly-trusted certificate; anything outside that — a private-CA endpoint, or a store needing path-style addressing — is not reachable by configuration today. Making the endpoint explicit does not widen what it can point at, and that gap is left open here deliberately rather than silently.
