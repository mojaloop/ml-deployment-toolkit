# Documentation Governance

How documentation in `doc/` is written, structured, and maintained.

`doc/` is the active documentation root. The older `docs/` tree is retained for reference and is **not maintained** — content is being verified and migrated here. Nothing in `doc/` should link into `docs/`.

## The rule that overrides every other rule

**If a reader cannot execute it today, it does not ship.**

No planned features. No documented interfaces that do not exist. No commands that are not in the `Makefile`. No files that are not in the repository. When a capability exists but its convenience wrapper does not, document the capability as it actually works.

Two exceptions, both narrow and both explicit:

**Decision records.** See [Decision tracing](#decision-tracing). An ADR is a historical record, not an instruction; nobody executes it.

**Planned security controls.** Where a security layer is designed but not yet implemented, it is documented and marked **Work in progress** in the heading. Architecture readers need to know which controls exist, which are coming, and what the endpoint relies on in the meantime — omitting a planned control implies the surface is complete when it is not.

This applies to architecture only. A *procedure* never contains an unimplemented step, and a WIP section never appears in a guide a reader is following to get something done.

## Audiences

Five audiences, each with one core question. Every document declares its audience explicitly.

| Audience | Core question | Who they are |
|----------|--------------|--------------|
| **Architect** | *Why is it built this way?* | Evaluating or extending the design |
| **Platform developer** | *How do I build and extend the distribution?* | Contributing to this codebase |
| **System integrator** | *How do I tailor it for a client and stay on the upstream track?* | Forking, changing code, publishing their own OCI artifact |
| **Adopter** | *How do I run a Hub?* | Deploying and operating Mojaloop |
| **Participant** | *How do I connect to a Hub?* | An institution joining an existing scheme |

Adopter and Participant have distinct lifecycle phases and are split into journeys. Architect, Platform developer, and System integrator do not.

| Audience | Journeys |
|----------|----------|
| Adopter | Deploy · Recover · Operate |
| Participant | Integrate · Operate |

**Platform developer vs System integrator.** Both change code. The difference is where it lands: a platform developer contributes to this repository; a system integrator maintains a derivative and publishes their own OCI artifact. Configuration-level customization requires neither — it needs no fork and no code change, so it belongs to the Adopter (deploy) journey.

## Vocabulary

Reader-facing terms are fixed. Code identifiers are not renamed — they are mapped once, in [Configuration](adopter/deploy/configuration.md#vocabulary), and never re-explained.

| Concept | Use | Never use | Code identifier |
|---------|-----|-----------|-----------------|
| Management-plane cluster | **Tooling Cluster** | Control Center, CC | `role: cc` |
| Mojaloop switch cluster | **Hub** | Switch, App Environment, env cluster, SW | `role: env` |
| Connecting institution | **Participant** | DFSP (in prose) | `dfsp`, `DFSP_ID` |

`DFSP` remains correct when naming a code identifier, an environment variable, or a Mojaloop API field.

## Structure

```
doc/
  DOCUMENTATION.md            # This file — governance
  index.md                    # Entry point — routes by audience

  architecture/               # Owns every design fact and rationale
    index.md
    system-overview.md
    provider-model.md
    gitops-structure.md
    networking.md
    security.md
    participant-mtls.md
    participant-integration.md  # Onboarding choreography + interface contract
    observability.md
    data-layer.md
    decisions/
      NNN-short-title.md

  platform/                   # Contributors to this codebase
  integrator/                 # Fork, customize, publish, rebase

  adopter/
    index.md
    deploy/                   # Prerequisites, provider setup, config, deployment
    recover/                  # Backup, restore, disaster recovery
    operate/                  # Monitoring, troubleshooting, day-2

  participant/
    index.md
    integrate/                # Connect to a Hub
    operate/                  # Run the connection
```

### Single source of truth

Every fact lives in exactly one place. Other documents **link**. This is enforced strictly:

- **Architecture owns all design facts.** Platform, integrator, adopter, and participant docs reference architecture; they never restate it.
- **Platform owns the internals reference** — module pipeline, adding providers and services, building artifacts. Integrator references it.
- **Integrator owns only what is unique to maintaining a derivative** — what to fork, publishing your own artifact, version pinning, rebasing on upstream. It is thin by design.

```markdown
<!-- Good -->
The Hub terminates participant mTLS at a standalone Envoy —
see [Participant mTLS](architecture/participant-mtls.md#inbound-participant-to-hub).

<!-- Bad: restating the architecture in a guide -->
```

If you find yourself explaining *why* inside a procedure, the explanation belongs in `architecture/` and the procedure should link to it.

### The one permitted duplication

The participant onboarding choreography is a two-party sequence. Its diagram may appear in both the adopter and participant guides, because a reader on either side must see the whole exchange to know where they are.

`architecture/participant-integration.md` is the canonical source. Copies carry a note saying so. The *procedures* are never duplicated — only the sequence diagram.

Each side of the choreography declares its interface explicitly:

- **What you need from the other party** (inbound)
- **What you must hand back** (outbound)

These two tables are what make the guides independently readable, and what will allow the participant half to move to the Integration Toolkit repository later as a clean cut rather than a rewrite.

## Decision tracing

Every non-obvious design choice gets a record in `architecture/decisions/`. Records are **append-only**. A decision that no longer reflects the system gets a status update and a pointer to its successor — never deletion. This is the sole exception to the executability rule.

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

Second person, present tense, active voice. Procedures address the reader directly: *"Create the secret before installing"*, not *"The secret should be created"*.

Architecture and decision records may use impersonal register — they describe a system, not a task. Everything else speaks to a person doing something.

State what a step does before the command. Name the expected result. When something commonly looks stuck but is not, say so and give the duration.

## Diagrams

### Mermaid (default)

Mermaid renders natively in GitHub, needs no build step, and diffs readably.

**Arrows show who acts, not where data ends up.** An arrow starts at the component performing the action and is labelled with the action. This is the difference between a diagram you can act on and one you have to decode.

```
Good — Alloy is the actor; you can see what to debug:
    alloy -->|"scrapes"| node-exporter
    alloy -->|"writes metrics"| thanos

Bad — data flow hides who initiates:
    node-exporter --> alloy --> thanos
```

The second version reads as though node-exporter pushes to Alloy. It doesn't — Alloy pulls. When something breaks, the actor is what you go and look at, so the actor is what the diagram must name.

- **Line breaks in node labels use `<br/>`, never `\n`.** Mermaid does not interpret `\n` inside quoted strings — it prints the characters literally.
- **No hardcoded colours.** `style x fill:#f0f4ff` is invisible in dark mode. Use `classDef` with theme-neutral values, or no styling.
- Keep diagrams under ~15 nodes; split or move to SVG beyond that.
- Use `flowchart`, not `graph`.
- Descriptive node IDs: `vault["Vault"]`, not `A["Vault"]`.

### SVG (dense layouts only)

Where auto-layout fails — topologies with meaningful spatial arrangement:

- Author in [draw.io](https://app.diagrams.net/) or Excalidraw
- Export `.drawio.svg` / `.excalidraw.svg`; commit the editable source alongside
- Store in `doc/diagrams/`, reference as `![title](../diagrams/name.svg)`
- Must handle light and dark backgrounds, and must not use a fixed pixel width

Prefer Mermaid unless you have tried it and the result is unreadable.

## Maintenance

Documentation is updated in the **same PR** as the code when:

- A provider, DNS provider, or platform service is added or removed
- A configuration option changes
- A design decision is made or reversed
- A known issue appears or is fixed
- A deployment or recovery procedure changes
- A component is replaced

That last one is not hypothetical. The auth stack was replaced without the documentation following, and the guides described a system the code could no longer run.

### Review checklist

- [ ] Every command, path, and file referenced exists and runs today
- [ ] Namespaces in `kubectl` commands match the manifests
- [ ] Facts live in one place; other docs link
- [ ] Links point to sections, not just pages
- [ ] No planned or aspirational content
- [ ] Audience declared, breadcrumb present
- [ ] Diagrams use `<br/>`, no hardcoded fills, render in dark mode
- [ ] Nothing added to `doc/` is orphaned
