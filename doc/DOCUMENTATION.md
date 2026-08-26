# Documentation Governance

How documentation in `doc/` is written, structured, and maintained.

## The rule that overrides every other rule

**If a reader cannot execute it today, it does not ship.**

No planned features. No documented interfaces that do not exist. No commands that are not in the `Makefile`. No files that are not in the repository. When a capability exists but its convenience wrapper does not, document the capability as it actually works.

Two exceptions, both narrow and both explicit:

**Decision records.** See [Decision tracing](#decision-tracing). An ADR is a historical record, not an instruction; nobody executes it.

**Planned security controls.** Where a security layer is designed but not yet implemented, it is documented and marked **Work in progress** in the heading. Architecture readers need to know which controls exist, which are coming, and what the endpoint relies on in the meantime — omitting a planned control implies the surface is complete when it is not.

This applies to architecture only. A *procedure* never contains an unimplemented step, and a WIP section never appears in a guide a reader is following to get something done.

## What, why, how

Every statement in `doc/` is one of three kinds, and each kind has exactly one home:

| Kind | Home | Register |
|------|------|----------|
| **What** — the system as built: components, topology, mechanisms, interfaces, constraints, and their observable consequences | `architecture/` | Impersonal, present tense |
| **Why** — the justification for a choice: context, alternatives considered, what was rejected and what that costs | `architecture/decisions/` | Historical record |
| **How** — a procedure a named audience follows, plus the reference tables and known issues that serve it | `platform/`, `integrator/`, `adopter/`, and the [Integration Toolkit](https://github.com/mojaloop/integration-toolkit) for participants | Imperative |

This file is the meta-how: the rules for writing the other three. Process rationale — why records are append-only, why forks stay narrow — belongs here or in the guide that applies it, never in an ADR.

**The boundary test between what and why.** A sentence that could change because the project changed its mind — without the running system changing — is a *why* and belongs in a decision record. A sentence that describes what the running system does, and what follows from that, is a *what* — even when it is phrased with "because". *"`hub-vault` waits for the MySQL cluster to report ready, so a Hub takes longer to converge"* is a what. *"Gating on cluster health rather than object existence was chosen over retry loops because…"* is a why. Architecture states the mechanism and links the decision; it does not argue for it.

**Reference placement.** Design facts live in `architecture/`; guides link to them. Interface facts — configuration keys, command tables, port lists, plan-time rules — live in the guide that serves them; architecture links to those. Both directions, one owner per fact.

## Audiences

Five audiences, each with one core question. Every document declares its audience explicitly.

| Audience | Core question | Who they are |
|----------|--------------|--------------|
| **Architect** | *Why is it built this way?* | Evaluating or extending the design |
| **Platform developer** | *How do I build and extend the distribution?* | Contributing to this codebase |
| **System integrator** | *How do I tailor it for a client and stay on the upstream track?* | Forking, changing code, publishing their own OCI artifact |
| **Adopter** | *How do I run a Hub?* | Deploying and operating Mojaloop |
| **Participant** | *How do I connect to a Hub?* | An institution joining an existing scheme |

Adopter journeys (Deploy · Recover · Operate) live in `adopter/`. **The participant journey lives in the [Integration Toolkit repository](https://github.com/mojaloop/integration-toolkit)** — a participant reads that documentation and nothing else. This repository keeps the hub side of the relationship: the [integration contract](architecture/participant-integration.md) and the adopter's onboarding procedure. `participant/index.md` is a signpost, nothing more.

**Platform developer vs System integrator.** Both change code. The difference is where it lands: a platform developer contributes to this repository; a system integrator maintains a derivative and publishes their own OCI artifact. Configuration-level customization requires neither — it needs no fork and no code change, so it belongs to the Adopter (deploy) journey.

## Vocabulary

Reader-facing terms are fixed. Code identifiers are not renamed — they are mapped once, in [Configuration](adopter/deploy/configuration.md#vocabulary), and never re-explained.

| Concept | Use | Never use | Code identifier |
|---------|-----|-----------|-----------------|
| Optional cluster hosting the supporting services a Hub points at — registry and pull-through cache, backup target, telemetry sink | **Tooling Cluster** | Control Center, CC, management plane | `role: tooling` |
| Mojaloop switch cluster | **Hub** | Switch, App Environment, env cluster, SW | `role: hub` |
| Connecting institution | **Participant** | DFSP (in prose) | `dfsp`, `DFSP_ID` |

A Tooling Cluster is a reference implementation of the three supporting-service endpoints, not a control plane: each endpoint may point anywhere — a Tooling Cluster, a cloud service, or the adopter's own hosts.

`DFSP` remains correct when naming a code identifier, an environment variable, or a Mojaloop API field.

## Structure

```
doc/
  DOCUMENTATION.md            # This file — governance (the meta-how)
  index.md                    # Entry point — routes by audience

  architecture/               # What: every design fact, stated impersonally
    index.md
    system-overview.md
    provider-model.md
    gitops-structure.md
    networking.md
    security.md
    participant-mtls.md
    participant-integration.md  # The participant integration contract (versioned)
    observability.md
    data-layer.md
    decisions/                # Why: append-only records
      NNN-short-title.md

  platform/                   # How: contributors to this codebase
  integrator/                 # How: fork, customize, publish, rebase

  adopter/
    index.md
    deploy/                   # Prerequisites, provider setup, config, deployment
    recover/                  # Backup, restore, disaster recovery
    operate/                  # Monitoring, troubleshooting, day-2

  participant/
    index.md                  # Signpost to the Integration Toolkit
```

### Single source of truth

Every fact lives in exactly one place. Other documents **link**. This is enforced strictly:

- **Architecture owns design facts** — mechanisms, topology, constraints. Guides reference them; they never restate them.
- **Guides own their reference and known issues** — configuration keys, commands, ports, plan-time rules. Architecture links to them.
- **Decision records own rationale.** A what-page states the mechanism and cites the ADR by number; it does not repeat the argument.
- **Platform owns the internals reference** — module pipeline, adding providers and services, building artifacts. Integrator references it.
- **Integrator owns only what is unique to maintaining a derivative** — what to fork, publishing the derivative artifact, version pinning, rebasing on upstream. It is thin by design.

```markdown
<!-- Good -->
The Hub terminates participant mTLS at a standalone Envoy —
see [Participant mTLS](architecture/participant-mtls.md#inbound-participant-to-hub).

<!-- Bad: restating the architecture in a guide -->
```

### The integration contract and its mirrors

`architecture/participant-integration.md` is the **contract** between the Hub and the Integration Toolkit: the onboarding choreography, both interface tables — what the hub hands the participant, what the participant returns — and the protocol semantics both sides implement. It carries a revision number and a changelog.

Because a participant reads only the Integration Toolkit's documentation, the contract material a participant needs day-to-day is **mirrored** there. Mirrors are the only sanctioned duplication, and each one:

- names its canonical source and section,
- cites the contract revision it was written against.

The contract page lists every mirror in a registry. A change to the hub side of the boundary bumps the contract revision **in the same PR**; a mirror citing an older revision is visibly stale on read.

## Decision tracing

Every non-obvious design choice gets a record in `architecture/decisions/`. Records are **append-only**. A decision that no longer reflects the system gets a status update and a pointer to its successor — never deletion. This is the sole exception to the executability rule. Append-only serves the reader: the reasoning stays useful even when the conclusion changes.

```markdown
# NNN — Short title

**Date:** YYYY-MM-DD
**Status:** accepted | superseded by [NNN](NNN-title.md) | deprecated
**Audiences:** architect, platform developer

## Context
## Alternatives considered
## Decision
## Consequences
```

Reference by number: *"Metrics use Thanos ([ADR-003](architecture/decisions/003-thanos-over-mimir.md))"*.

## Known issues

Each audience folder owns a `known-issues.md` scoped to that audience's activities. The audience who **encounters** the issue owns the entry; others cross-link.

```markdown
### Title (component, version)

**Symptoms:** What the reader sees.
**Root cause:** Why it happens.
**Fix/workaround:** What to do now.
**Prevention:** How to avoid it next time.
```

Resolved issues are deleted, not archived. A known-issues entry describing a fixed problem is worse than no entry — it sends readers to undo working configuration.

## Navigability

Every document has:

1. **A breadcrumb** as the first line after the title:
   `[doc](../index.md) / [adopter](../index.md) / Deploy`
2. **An audience declaration:** `**Audiences:** adopter (deploy)`
3. **A table of contents** for documents longer than five sections
4. **Deep-linkable headings** — link to the section, not the page

Any document is reachable within two clicks of `index.md`. An orphaned file — one nothing links to — is a defect, not an oversight.

## Voice

Third person, present tense, active voice. Prose names the acting role from the [audience table](#audiences) — *the participant*, *the adopter*, *the Hub operator*, *the integrator*, *the platform developer* — never "you" or "your". In any page describing an exchange between parties, "you" has no fixed referent; the named actor always does.

Procedure steps use the bare imperative: *"Create the secret before installing"*, not *"The secret should be created"*. The imperative names no actor and inherits the document's declared audience. Possessives follow the same rule: *"the participant's FQDN"* or simply *"the FQDN"*, never *"your FQDN"*.

Architecture and decision records use impersonal register — they describe a system, not a task.

State what a step does before the command. Name the expected result. When something commonly looks stuck but is not, say so and give the duration.

## Diagrams

### Mermaid (default)

Mermaid renders natively in GitHub, needs no build step, and diffs readably.

**Arrows show who acts, not where data ends up.** An arrow starts at the component performing the action and is labelled with the action. This is the difference between a diagram a reader can act on and one they have to decode.

```
Good — Alloy is the actor; the reader sees what to debug:
    alloy -->|"scrapes"| node-exporter
    alloy -->|"writes metrics"| thanos

Bad — data flow hides who initiates:
    node-exporter --> alloy --> thanos
```

The second version reads as though node-exporter pushes to Alloy. It doesn't — Alloy pulls. When something breaks, the actor is what the operator goes and looks at, so the actor is what the diagram must name.

- **Line breaks in node labels use `<br/>`, never `\n`.** Mermaid does not interpret `\n` inside quoted strings — it prints the characters literally.
- **No hardcoded colours.** `style x fill:#f0f4ff` is invisible in dark mode. Use `classDef` with theme-neutral values, or no styling.
- Keep diagrams under ~15 nodes; split or move to SVG beyond that.
- Use `flowchart`, not `graph`.
- Descriptive node IDs: `vault["Vault"]`, not `A["Vault"]`.

### SVG (dense layouts only)

Where auto-layout fails — topologies with meaningful spatial arrangement:

- SVG is text — the committed file is the editable source; use any tool that writes clean SVG
- Store in `doc/diagrams/`, reference as `![title](../diagrams/name.svg)`
- Give the diagram its own background rect, so it reads identically on light and dark pages
- Size with `viewBox` only — no fixed `width`/`height`, so the diagram scales to its container

Prefer Mermaid unless it has been tried and the result is unreadable.

## Maintenance

Documentation is updated in the **same PR** as the code when:

- A provider, DNS provider, or platform service is added or removed
- A configuration option changes
- A design decision is made or reversed
- A known issue appears or is fixed
- A deployment or recovery procedure changes
- A component is replaced
- **Anything crossing the participant boundary changes** — the contract revision is bumped in the same PR

That last group is not hypothetical. The auth stack was replaced without the documentation following, and the guides described a system the code could no longer run.

### Review checklist

- [ ] Every command, path, and file referenced exists and runs today
- [ ] Namespaces in `kubectl` commands match the manifests
- [ ] Facts live in one place; other docs link
- [ ] Rationale lives only in `architecture/decisions/`; what-pages cite ADRs by number
- [ ] Links point to sections, not just pages
- [ ] No planned or aspirational content
- [ ] Audience declared, breadcrumb present
- [ ] Mermaid diagrams use `<br/>` and no hardcoded fills; SVGs carry their own background
- [ ] Mirrors of contract material name their canonical source and revision
- [ ] Nothing added to `doc/` is orphaned
