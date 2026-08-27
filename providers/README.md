# Provider packages

One directory per provider: **everything provider-specific, colocated**.
Providers are not generalized — each package stands alone, and duplication
between packages is the accepted cost (design doc: Gardener's GEP-1 regret of
in-tree generalization). What a package must supply is fixed by the provider
contract (params.schema.json); how it supplies it is its own business.

A template is a **full overlay for one provider, role and capacity** — no knobs,
no conditionals. Selection is `infra.provider` + `cluster.role` + `template`
from the environment's config.yaml.

```
<provider>/                 # proxmox | aws | digitalocean
  params.yaml               # contract implementation: P_* symbols, capabilities, infra block
  patches/                  # provider-owned machine-config patch files (proxmox)
  terraform/                # the provider's Terraform modules (cluster, vm, ...)
  templates/
    <role>/                 # bare | hub | tooling
      <name>/               # dev | tps-1 | tps-10 | small | medium
        template.yaml       # identity
        placement.yaml      # the SHAPE: node pools, sizing, default topology
        values/<ns>/<rel>.yaml # gitops deltas — template slot of the valuesFrom chain
        patches/<kust>.yaml # kustomize patches, applied after distribution, before environment
        talos/<pool>.yaml   # per-pool Talos machine-config fragments
```

The engine (config-loader, flux-config, flux-bootstrap) lives apart in
`src/engine/` — nobody authors per-deployment content there.

Layer order everywhere is common → template → environment; later wins.
The environment overrides pools **by name** in its own placement.yaml
(partial keys inherit the rest; `enabled: false` drops a pool), and its
values/patches/talos files use the same paths as here — diffing an override
against its base is a direct path comparison.

Duplication across providers is the accepted cost of no-knobs: copy another
provider's role directories and adjust. A template that grows to the size of
the common layer means the provider interface is wrong — fix params.schema.json
instead.

Talos fragments follow Talos merge semantics: lists append; never restate a
list; remove entries with `$patch: delete`; JSON6902 is not allowed here
(rejected on multi-document machine configs).
