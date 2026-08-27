# Configuration layering — confirmed design

[doc](../index.md) / [architecture](index.md) / Config-layering design

**Audiences:** architect, platform developer

2026-08-14. Records the decisions settled so far, including the review round. Everything
below is agreed; remaining work is listed at the end.

> **Implementation status (2026-08-15):** implemented on this repository. The one
> deliberate mapping deviation: the common layer keeps its Flux-layer directory
> structure (the reconcile graph is load-bearing) rather than a literal
> `common/<role>/` tree — the role split is expressed by the Kustomization graph,
> and path symmetry is preserved at the layer level: every common release default
> lives at `gitops/<layer>/values/<namespace>/<release>.yaml`, the same
> `values/<namespace>/<release>.yaml` suffix as the template and environment
> layers. The interface schema lives with the other schemas at
> `config/schemas/params.schema.json`.

## Model

Two orthogonal axes. They are not a single precedence ladder.

**Composition** — the same document kinds merged in order:

| Layer | Owner | Contents |
|---|---|---|
| 0. Common | DTK | Provider-agnostic gitops, split by role: `values/`, `patches/`. Written against a declared provider interface. |
| 1. Template | DTK | Full overrides for one provider, role and capacity: gitops deltas plus `placement.yaml`, `proxmox/`, `talos/`. |
| 2. Environment | Adopter | Same file kinds, overriding both gitops and infra. |

**Parameterization** — `config.yaml` and `.env`, applied across all layers. Not a
precedence level.

Keeping these separate is the point. Treating `config.yaml` as "layer 3, highest priority"
either forces it to re-declare the whole schema or makes it silently work for only the keys
someone remembered to wire up.

### No knobs

Templates carry full overrides, not conditionals. Conditionals inside a shared document are
what made the previous arrangement unreadable. The cost is duplication across providers and
drift when common moves, which is contained by keeping each template a delta from common and
by CI failing when common introduces a key no provider handles. A template that grows to the
size of common means the interface is wrong.

## Project layout

The DTK repository is public and must be treated as such: **adopters never commit to it.**
Adopter data lives in sibling directories under a project root, outside the clone:

```
<project-root>/                   # on this workstation: ~/Workspace/mojaloop/dtk
  ml-deployment-toolkit/          # this repo — public, read-only, pristine clone at a tag
  environments/<env>/             # adopter-owned, their own private git repo
  artifacts/<env>/                # generated output, adopter's own backup mechanism
```

The repository keeps its name and moves inside the project root — on this workstation
`~/Workspace/mojaloop/dtk/ml-deployment-toolkit` — so `dtk/` contains the clone and the
adopter-owned sibling trees.

This is the established shape for the problem — Big Bang customer deployment repos against a
pinned upstream, Terragrunt's live/modules split, kubespray's out-of-tree inventory. Upstream
is read-only software; adopter data is a separate repo with its own lifecycle.

What it buys:

- **No public-push risk.** The adopter physically cannot commit into DTK, so no gitignore
  gymnastics are needed to protect env data — DTK's `.gitignore` rules for
  `environments/*` disappear along with the problem they solved.
- **Upgrades are a checkout, never a rebase.** There is no merge scenario.
- **The drift check collapses.** The DTK clone should be pristine: `git status --porcelain`
  empty and `git describe` matching the declared version. No path exclusions.
- **Environment independence for adopter tooling.** Each env repo and artifact tree carries
  its own lifecycle, backup policy and access control.

Consequences:

- **Paths become a parameter.** The incumbent hardcodes `../../environments/${var.env_name}`
  (`src/config/main.tf:29`); the entry point takes an environment directory path, defaulting
  to the sibling layout.
- **The version assert is load-bearing.** Clone and env repo skew independently by design,
  so the `config.yaml` version key checked against the clone's actual tag at apply time is
  what keeps "matched versions only" true. A mismatch fails, it does not warn.
- **The reference environment is copy-out material.** A complete example env committed in
  DTK that adopters copy into their own repo as day one. It is the de facto shared layer —
  every adopter env will be a fork of it — so it has to be good and stay current. It ships
  its own `.gitignore` ignoring `.env`, so secrets stay out of git even in a private repo.
- **Editing the clone is forking public software.** Still physically possible — it is a
  local clone — but unambiguously outside the contract and reported by the pristine check.
- **No submodule.** Pinning DTK as a git submodule of a project repo would record the
  version in git, but submodule ergonomics are a permanent tax; the version key plus hard
  assert achieves the same pinning without it.

## Tree

Inside the DTK repo:

```
ml-deployment-toolkit/
  common/
    params.schema.yaml            # the provider interface: declared symbols, types, required/optional
    <role>/                       # hub | tooling | bare
      values/<namespace>/<release>.yaml
      patches/
  templates/
    <provider>/                   # proxmox-talos
      params.yaml                 # provider symbols satisfying common/params.schema.yaml
      <role>/
        <name>/                   # dev | tps-1 | tps-10
          values/<namespace>/<release>.yaml
          patches/
          placement.yaml
          proxmox/
          talos/<pool>.yaml
```

Adopter-side, per environment:

```
environments/<env>/               # adopter's own repo
  config.yaml
  .env                            # never committed, even to the adopter's repo
  values/<namespace>/<release>.yaml
  patches/
  placement.yaml
  proxmox/
  talos/<pool>.yaml

artifacts/<env>/
  state/                          # Terraform state — the non-regenerable part
  …                               # rendered manifests, plans, kubeconfig, talosconfig
```

Template selection already exists today as `config/templates/<role>/<template>.yaml`; making
templates provider-specific keeps that axis and makes each one richer. `dev`, `tps-1` and
`tps-10` are capacity variants of a role, and template names stay short and mean the same
thing under every role.

`config/templates/mappings/<provider>.yaml` disappears. It exists to translate a generic
template into provider terms, and a template that is already provider-specific has nothing to
translate.

Common splits by role because hub, tooling and bare deploy substantially different workloads.
A flat common would hold either a mixture or only their small intersection, and the rest would
land in provider-specific templates where a second provider would duplicate it. The interface
schema itself sits at the common root, deliberately role-agnostic: providers implement one
contract, not one per role.

Environment directories are flat — no `gitops/` and `infra/` grouping. Paths stay identical to
the layers above, so diffing an override against its base is a direct path comparison.

`placement.yaml` sits at the layer root beside `proxmox/` and `talos/` rather than inside
either. It drives both — VM specs on one side, node roles and labels on the other — and it is
the file adopters edit most.

## Scope of the layering

No fleet or group layer. Providers are independent of each other; environments are independent
of each other and never inherit. Copy-paste between environments is the adopter's problem to
manage.

## Merge semantics

**Each file kind keeps its native engine's semantics — no DTK dialect, no fight with the
tools.** Maps deep-merge everywhere. List behaviour differs by engine and is stated per kind
rather than papered over with a universal rule:

| Kind | Lists |
|---|---|
| `values/` | Replace (Helm) |
| `patches/` | Kustomize: merge keys on built-in types, JSON6902 for appends |
| `talos/` | **Append** by default (Talos), keyed or replace only where Talos defines it |
| `proxmox/`, `placement.yaml` | DTK-owned Terraform merge; pools keyed by name |

**In `values/`, a restated list replaces the base list.** Helm default, predictable.

**Appending is what `patches/` is for.** When an environment needs to add to a list rather than
restate it, the route is a JSON6902 patch using `add` with `/-`. This turns the limitation into
a teachable rule — if you are restating a list in values, you want a patch — and avoids the
silent rot where a restated list stops tracking upstream as the base evolves.

Kustomize strategic merge honours patch merge keys on built-in types, so containers merge by
name, env vars by name, volumes by name. Lists on CRDs it has no schema for replace.

**In `talos/`, never restate a list.** Talos strategic merge appends lists by default —
`certSANs`, `disks`, `extraMounts` all concatenate, so a restated list silently duplicates
entries. The teachable rule is the values rule inverted: state only the additions (native
append), remove entries with `$patch: delete`. Keyed merge exists only where Talos defines it
(network interfaces by `interface`/`deviceSelector`, VLANs by `vlanId`); there is no
`$patch: replace`. Only strategic-merge patches are used in `talos/` — JSON6902 is avoided
there because Talos rejects it outright on multi-document machine configs, and Talos is
actively migrating features into extension documents. One silent failure mode needs a guard:
a patch document whose `kind`/`name` matches no existing document is appended as a new
document, not an error — the offline render runs `talosctl validate` on the merged config and
a lint flags unmatched patch documents. (Semantics verified 2026-08-14 against the Talos
1.8–1.10 docs and machinery source, closing the earlier open question.)

**VM pools match by name; overrides replace whole top-level fields.** Pools are keyed
entities, so an environment changing the worker count inherits the control-plane and every
other pool untouched. Within a matched pool the merge is deliberately SHALLOW: each field the
override names replaces the template's field wholesale — lists included, so overriding
`taints` or `disks` restates the whole list, and nothing inside a field is deep-merged.
Fields the override omits are inherited. (Decided 2026-08-27: list deep-merge is ambiguous
for disks/taints; explicit wholesale replacement is legible.) Removing a default pool is
expressed as `enabled: false` on that pool — greppable, and visible in the environment file as
a deliberate decision rather than an absence.

## Substitution

Two engines, split by **who applies the file** — not by infra versus gitops:

| Files | Engine | Errors surface |
|---|---|---|
| Artifact layers 0/1 (public, tokens only) | Flux `postBuild.substituteFrom` (cluster-config ConfigMap + cluster-secrets Secret) | in-cluster |
| Environment `values/`, `patches/` | Terraform, at apply (incumbent: `templatefile()`, `src/config/main.tf:32,49`) | at apply |
| `talos/`, `proxmox/`, `placement.yaml` | Terraform, at apply | at apply |

The split is forced, not chosen. The OCI artifact is public and contains only `${VAR}` tokens,
never values — that is why it can be public. Flux substitutes it in-cluster as it applies it,
reading the parameter ConfigMap and Secret that Terraform landed. Environment files are turned
into ConfigMaps by Terraform directly; Flux never applies them, and helm-controller reads
`valuesFrom` content verbatim — so Terraform must substitute them itself, which it can, since
`config.yaml` and `.env` sit in the same directory. This is already the incumbent mechanism;
`templatefile()` also hard-fails on undefined variables, which is the decided behaviour.

The two engines are kept behaviourally identical — same syntax, same fail-on-undefined — as a
CI-tested invariant. Two supports make that invariant true rather than aspirational:

- **Flux floor: kustomize-controller ≥ 1.9 (Flux 2.7).** Fail-on-undefined only exists on the
  Flux side from that line (`StrictPostBuildSubstitutions` default-on); older Flux silently
  renders undefined variables as empty strings. The tool-version manifest pins Flux at or
  above it, with the reason stated so nobody downgrades past it. Flux Kustomizations also set
  `substituteStrategy: Always` — the 1.9 default (`WithVariables`) skips substitution entirely
  when zero variables resolve.
- **The lint enforces the shared subset: bare `${UPPER_SNAKE}` only.** The engines genuinely
  agree only there. Flux's envsubst accepts bash-style operators (`${VAR:-x}`, `${VAR/p/r}`,
  case and substring forms) that are hard syntax errors in `templatefile()`, and
  `templatefile()` treats `%{` as active directive syntax that Flux ignores — so operator
  forms and `%{` are forbidden in substituted files. The escape `$${VAR}` → literal `${VAR}`
  happens to be portable across both engines and is the one sanctioned escape.

**`${UPPER_SNAKE}` on both sides.** Flux's native form is already `${VAR}` and Terraform's
`templatefile` uses the same delimiters, so uniformity costs nothing. Upper-snake makes a
parameter visually distinct from ordinary YAML content, and adopters learn one rule.
(Incumbent uses lower-snake on the Terraform side; mechanical rename.)

**No inline defaults.** `${VAR:=fallback}` is forbidden. Every referenced parameter must be
declared or the render fails. An inline default is a hidden default buried in a file nobody
reads, and it turns a missing key into a silently wrong value instead of an error.

**All three layers may reference parameters.** Common needs `${CLUSTER_DOMAIN}` more than an
environment does, and an environment writing the literal instead of the reference is exactly
what the hardcoded-literal lint exists to catch.

### Secrets rule

A substituted secret must never land in a ConfigMap.

- **Environment layer:** a values file that references only `config.yaml` params becomes a
  ConfigMap; one that references any `.env` key becomes a Secret. `valuesFrom` accepts both
  kinds, so the rule is mechanical. (New behaviour — incumbent makes everything a ConfigMap.)
- **Artifact layers:** Flux substituting a secret token into a ConfigMap manifest produces a
  plaintext ConfigMap in etcd, so DTK-authored documents that consume secret tokens are
  authored as Secret-shaped resources. A base-authoring rule, not machinery.

## Provider interface

Common declares the symbols it requires — storage classes, ingress and gateway classes, LB
pools, node role labels, DNS mechanism, secrets backend, registry — in
`common/params.schema.yaml`, with types and required/optional. Each provider ships a
`params.yaml` satisfying it.

CI enforces both directions: a provider missing a declared symbol fails, and a reference in
common to an undeclared symbol fails. This makes the interface a checkable contract rather than
a convention, and defines a symbol once no matter how many releases consume it.

**Provider symbols and `config.yaml` are separate namespaces.** Provider symbols resolve from
`params.yaml` only; `config.yaml` cannot shadow them. This keeps "read `config.yaml` to know
your parameters" literally true and keeps resolution single-source per symbol. A symbol defined
in both places is a hard error — CI asserts the two key sets are disjoint. Provider symbols
carry a distinguishing prefix so a reader seeing `${X}` in common can tell at a glance whether
it is theirs to set.

An adopter whose hardware genuinely differs edits `params.yaml` in their clone. That is a
visible fork the pristine check reports.

## VM placement

Node topology: control plane and worker counts, dedicated pools (kafka, mysql), which host each
VM lands on, sizing.

Split by layer:

- **Template owns the shape** — what a node pool is for this provider, role and capacity: disk
  layout, Talos machine config per role, default sizing, the default topology.
- **Environment owns the instance** — counts, target hosts, sizes, extra pools.

Counts and hosts are facts about someone's hardware and cannot ship from DTK.

### Contract with gitops

Placement produces node labels and taints; gitops consumes them. This is a real cross-layer
contract and the one most likely to break silently. Three rules hold it:

1. **Labels derive from pool names.** A pool named `kafka` yields its label mechanically. The
   moment a human types the label key in both the Talos patch and the Helm values, they drift,
   and the failure is a Pending pod with no obvious cause.
2. **Pools declare their own taints**, in `placement.yaml`, once. Adding a tainted pool in an
   environment override can exclude workloads defined a layer away — including DaemonSets and
   system components nobody considered.
3. **Gitops references pools with soft affinity**, so an absent pool degrades to "schedules
   somewhere" rather than Pending forever. A check fails when a gitops nodeSelector names a pool
   the environment's placement does not define.

Workload placement — which pods land on which pool — stays in gitops. Only node topology and
labelling live here.

## Artifacts and state

`artifacts/<env>/` holds generated output: rendered manifests, plan files, kubeconfig,
talosconfig, generated Talos machine configs, and Terraform state. It sits outside both the DTK
clone and the adopter's env repo, with the adopter's own backup mechanism.

State is the exception in that directory and needs a visible boundary — a `state/`
subdirectory rather than sitting among the disposable output:

- **It is not regenerable.** Lose it and the cluster is orphaned: VMs still running, Terraform
  unaware of them, recovery is manual import surgery. Filing it under a word that means "build
  output" invites `rm -rf` as a cleanup step.
- **Backup policy differs.** State must be backed up; nothing else in the directory should be. A
  directory boundary is how that gets communicated.
- **It is secret-bearing.** Plaintext Talos machine secrets including the cluster CA key, next
  to kubeconfig, talosconfig and plan files. Mode 0600, a guard that fails when anything under
  `artifacts/` is staged in any repo, and support bundles built from a whitelist rather than by
  tarring the directory.

Per-environment state directories make cross-environment interference structurally impossible —
two environments cannot touch the same state file, so a concurrent apply on one cannot damage
the other.

**Local state only for now.** An object storage backend is a separate feature. Two things keep
that addition cheap: the state path stays a config parameter rather than a hardcoded default,
and nothing else in the design assumes state is a local file.

## Delivery

The adopter publishes no artifact. DTK publishes the gitops OCI artifact; Flux pulls it pinned
by version.

Terraform is the injection vehicle. It reads `environments/<env>/` and lands the overlay in the
cluster:

- environment `values/` → ConfigMaps and Secrets (substituted, per the secrets rule)
- environment `patches/` → the Flux Kustomization specs
- `config.yaml` parameters → the substitution ConfigMap
- `.env` → the substitution Secret

Talos and Proxmox never leave Terraform.

### Content, not topology

**Flux Kustomization CRs are Terraform-authored, never shipped in the artifact.** The artifact
contains only content — manifests and kustomize build files — never Flux topology. This is the
incumbent arrangement (`src/modules/flux-config/main.tf:765`) and it is load-bearing: env patch
injection, the `substituteFrom` wiring and the `valuesFrom` chains all assume Terraform owns the
CR specs. The common Flux idiom of self-managed topology (Kustomization CRs living in the
artifact) would make Flux revert Terraform's patch injection on every reconcile — adopter
overrides flapping between applied and reverted with no error anywhere. Stated as a rule so a
natural-looking refactor toward that idiom does not reintroduce the fight.

### Merge mechanism, native per file kind

No custom merge engine. Each file kind already has an ordered mechanism:

| Kind | Mechanism | Merges at |
|---|---|---|
| `values/` | Helm `valuesFrom` chain on each HelmRelease; later entries win | in-cluster |
| `patches/` | Flux Kustomization `patches:`, applied after the base | in-cluster |
| `talos/` | Talos provider `config_patches` list, applied in order | terraform apply |
| `proxmox/`, `placement.yaml` | Terraform locals merge | terraform apply |

The `valuesFrom` list *is* the layer order, visible in the HelmRelease spec.

Merging and substitution have different fault surfaces on the two sides: Terraform-side
mistakes fail fast, locally and loudly at apply; in-cluster mistakes surface minutes later and
need `flux get` / `kubectl` to diagnose. The docs say this rather than letting people discover
it.

### Requirement on the published artifact

Every HelmRelease carries its full `valuesFrom` chain — common, template, environment — with the
environment entry `optional: true` so an environment that overrides nothing still reconciles.
**Generated mechanically, never hand-written.** A missing slot is a component the adopter cannot
override without forking the clone. CI asserts the chain is complete for every release.

## Binding files to targets

Bind by path where the content cannot identify itself; by content where it can.

- **`values/<namespace>/<release>.yaml`** — a values file is an anonymous blob, so the path
  carries the binding. Namespace as a directory, since release names are only unique within a
  namespace. (Incumbent is flat `values/<chart>.yaml`; delta.)
- **`patches/`** — strategic merge patches already carry `apiVersion`, `kind`, `metadata.name`
  and `namespace`. The target is in the document by necessity. Filenames stay descriptive and
  free-form.
- **`talos/<pool>.yaml`** — machine config fragments do not say which nodes they apply to, so
  the path does, keyed on the same pool names as `placement.yaml`.

For `values/`, the path is the *entire* binding — no `target:` header, no mapping registry. That
buys three properties worth protecting: the file that sets something is findable by name alone;
the same path exists in all three layers, so diffing base against override is meaningful; and
presence or absence of a file is a complete answer to whether an environment overrides that
release. In-file targeting metadata destroys all three.

The adopter reads common and the templates in their clone — the base tree is its own catalogue.
Overriding something means copying its path into the environment repo.

## config.yaml

Four keeper categories. A value that fits none of them belongs in the overlay that consumes it.

1. **Multi-consumer.** Consumed in more than one place — this is what guarantees consistency.
2. **Bootstrap.** Needed before the layers are assembled. Terraform evaluates backend config
   outside the variable flow at `init`, so it cannot be reached by substitution.
3. **Structural selector.** Decides which content deploys rather than supplying a value. A small,
   closed set, named in the schema so it does not grow silently. These choices are genuinely
   environment-level, and expressing them as overlay edits would turn one conceptual choice into
   several coordinated edits an adopter must get right together.
4. **Adopter-must-set.** Single-consumer, but the adopter has to supply it. Keeps "everything you
   must fill in is in one file" true, which is the main thing that makes onboarding survivable.

Applied to the current `environments/ml-lab0-sw/config.yaml`:

| Key | Category | Outcome |
|---|---|---|
| `version`, `infra.provider`, `artifact.*` | bootstrap | stays |
| `cluster.name`, `cluster.vip`, `dns.*` | multi-consumer | stays |
| `cluster.lb_ipam.pools.*` | multi-consumer | stays — network facts used by gitops and DNS |
| `registry.*`, `object_storage.*`, `observability.*` | multi-consumer | stays |
| `template` | selector | stays |
| `cluster.role`, `data.*.mode`, `app.api_type` | selector | stays |
| `cert.*`, `email.*`, `alerting.*`, `app.hub.*` | adopter-must-set | stays |
| `infra.proxmox.placement.*` | single-consumer | → `placement.yaml` |
| `infra.proxmox.network_bridge`, `infra.proxmox.storage.*` | single-consumer | → `proxmox/` |

`artifact.version` must be a pinned version; `latest` is disallowed by schema — it contradicts
matched-versions-only, and the version assert cannot check a moving target.

The consistency guarantee only holds with two supports:

- **Overlays reference the parameter, never repeat its value.** `${CLUSTER_DOMAIN}`, not the
  literal. A lint fails when an overlay hardcodes a literal that also appears in `config.yaml`;
  without it the guarantee is a convention people violate in a hurry.
- **The file is schema'd and undefined substitutions are fatal.** On the Flux side an unknown
  key renders as the empty string, which is how a Service ends up with no domain. Declare keys
  with types and required/optional, validate before render, fail on undefined. (The Terraform
  side already hard-fails via `templatefile`.)

### .env

Secrets only. Disjoint from `config.yaml`, never shadowing it — a key settable in both places
reintroduces invisible state. Never committed anywhere, including the adopter's own private
repo; the reference environment ships a `.gitignore` saying so.

## Versioning and toolchain

Terraform, gitops and the OCI artifact release together and are used only at matched versions.
The `config.yaml` version key is asserted against the clone's actual tag at apply time; a
mismatch fails loudly rather than deploying a half-matched pair. With env repos and the DTK
clone versioned independently, this assert is what holds the model together.

The clone pins those three to each other. It does not pin the workstation toolchain:
tofu/terraform, provider plugins, helm, kustomize, talosctl, flux, jsonnet and jb, jq, and yq —
where the mikefarah/kislyuk distinction alone is a recurring source of confusing failures.

**A tool-version manifest plus a hard pre-apply gate.** No published image. The check must fail
the apply rather than warn, since a warning people learn to scroll past gives the documentation
outcome with extra steps.

`.terraform.lock.hcl` is committed rather than gitignored — the cheapest pin available, and
provider behaviour changes have caused real damage here. DTK records all supported platforms via
`terraform providers lock -platform=…`, so adopters never need to re-lock and the pristine check
stays clean.

## Cross-environment references

Environments referencing each other's outputs — a hub cluster storing state in the tooling
cluster's object storage, once that backend lands — are opaque endpoint references, the same
class as a DNS provider or SMTP host. They are not config inheritance, so environment
independence still holds. Worth stating once in the docs so "totally independent" is not read as
"may not reference".

## Deltas from the incumbent implementation

Where the incumbent already implements a decision, it is noted inline above. All of the
changes below are made on a dedicated branch, `refactor/config`, created from the current
default branch — not on the default branch directly. What actually changes:

- Repo relocates to `~/Workspace/mojaloop/dtk/ml-deployment-toolkit` (done 2026-08-14);
  `environments/` and `artifacts/` move out to project-root siblings under `dtk/`; env-dir
  path becomes an entry-point parameter (replacing `src/config/main.tf:29`).
- DTK `.gitignore` drops the `environments/*` rules; the pre-commit guard covers `artifacts/`.
- Substitution tokens rename to `${UPPER_SNAKE}` on the Terraform side.
- Env values files referencing `.env` keys land as Secrets instead of ConfigMaps.
- `values/` paths gain the namespace directory: `values/<namespace>/<release>.yaml`.
- Templates become provider-specific full overlays; `config/templates/mappings/` is removed.
- `config.yaml` sheds the single-consumer infra keys per the table above; `artifact.version`
  pinned by schema.
- `.terraform.lock.hcl` committed, multi-platform.

## Tooling this implies

- **Offline render.** Helm and kustomize are deterministic, so the CLI can replay the same values
  chain and patch list without a cluster. Authoring speed depends on not needing one to see what
  you just wrote. `flux diff kustomization` covers server-side truth.
- **Pristine-clone check** — `git status --porcelain` empty, `git describe` matches the declared
  version.
- **valuesFrom completeness check** in CI.
- **Provider interface checks** — every declared symbol supplied, no reference to an undeclared
  one, namespaces disjoint.
- **Engine-parity check** — Terraform and Flux substitution behave identically on the same
  inputs (syntax, fail-on-undefined); the substitution lint enforces the shared subset — bare
  `${UPPER_SNAKE}` only, no operator forms, no `%{`.
- **Talos render checks** — `talosctl validate` on the merged machine config; lint for patch
  documents whose `kind`/`name` match no existing document; lint against restated lists in
  `talos/` fragments.
- **Placement/gitops cross-check** — no nodeSelector naming an undefined pool.
- **Hardcoded-literal lint** against `config.yaml` keys.
- **Secret-placement check** — no `.env`-referencing values file lands as a ConfigMap; no
  artifact document substitutes a secret token into a ConfigMap.
- **Tool-version gate** before apply.

## Remaining work

- **Enumerate the interface symbols.** The mechanism is decided; the actual list is not written.
- **Interface validation waits on a real second provider**, tested against real infrastructure.

## Future work

Out of scope for this refactor; recorded so the deferrals stay visible decisions rather than
omissions.

- **Object-storage Terraform state backend.** Local state on one workstation is an accepted
  interim risk. The addition stays cheap by design: the state path is a parameter and nothing
  assumes state is a local file.
- **Secrets custody beyond `.env`.** Evaluate SOPS with age: secrets live encrypted and
  versioned in the env repo, and out-of-band custody shrinks from every secret to one age key
  (password manager, or a cloud KMS where no local key exists). It does not remove local
  custody — it shrinks it; that trade is the thing to evaluate.
- **Adopter-shared base layer.** An optional layer between template and environment for
  adopters running several envs, removing copy-paste between them without breaking
  environment independence (envs still never inherit from *each other*). Cheap to retrofit:
  `valuesFrom` chains are generated mechanically and Terraform owns the Kustomization specs,
  so it is one more optional slot — which is also why the completeness check should count the
  generated chain rather than assume exactly three entries.
- **Upgrade discipline.** Version management is its own subject. The mechanism the ecosystem
  converged on, to start from: upgrade one release at a time, and diff the new reference
  environment against the fork on each hop.
