# Reference environments

Complete example environments adopters copy out as day one. One per role:

- `hub/` — a Mojaloop hub (role: hub, template tps-10), including perf-testing
  samples.
- `tooling/` — the supporting tooling cluster (role: tooling, template medium).

## Day one

```sh
# from the project root (the directory containing ml-deployment-toolkit/)
cp -R ml-deployment-toolkit/examples/environments/hub environments/<your-env>
cd environments/<your-env>
for f in $(find . -name '*.sample'); do mv "$f" "${f%.sample}"; done
git init -b main            # each environment is its own private repo
$EDITOR config.yaml placement.yaml proxmox/proxmox.yaml .env
```

Then, from the clone: `make validate ENV=<your-env>`.

## Layout

| File | What it is |
|---|---|
| `config.yaml` | Everything you must fill in, in one file: identity, network facts, selectors, adopter-must-set values. Schema-validated. |
| `.env` | Secrets only. Never committed — the shipped `.gitignore` enforces it. |
| `placement.yaml` | Which physical node each template placement group lands on. The file you will edit most. |
| `proxmox/proxmox.yaml` | Proxmox facts: network bridge, storage pools. |
| `talos.yaml` | Talos node OS facts: nameservers, NTP servers. |
| `talos/<pool>.yaml` | Per-pool Talos machine-config fragments (lists APPEND — never restate; remove with `$patch: delete`). |
| `values/<namespace>/<release>.yaml` | Helm override for one release. The path is the binding; the same path exists in the layers below, so diffing against the base is a direct path comparison. |
| `patches/<kustomization>.yaml` | Deployer patches applied after the distribution's own. |

## Ground rules

- Reference parameters (`${DOMAIN}`), never repeat their values — one source
  per fact, and the lint enforces it.
- Restating a list in values replaces it; appending is what patches are for.
- The environment never overrides provider interface symbols (`P_*`): those
  come from the provider's `params.yaml` in the clone.
- Keep `dtk_version` set to the DTK release you deploy with; the plan fails
  on a mismatch rather than deploying a half-matched pair.
