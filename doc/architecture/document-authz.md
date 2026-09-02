# Document-composed authorization

Authorization is derived from the services' OpenAPI documents. Each service
image carries its document (`x-authz` annotations name the service, its
resource types and each operation's permission and scoping), and the IAM
provisioning service composes every registered document into the deployment's
gateway rules, Keto model and permission catalog. Oathkeeper and Keto reload
the composed artifacts in place; no hand-written access rules or permission
tuple lists exist in this repository.

The model and its rules are documented with the chart:

- `mojaloop-iam/docs/permission-model.md` (mojaloop/helm) — permissions,
  roles, scoping, resource names
- `mojaloop-iam/docs/gateway-authz-architecture.md` (mojaloop/helm) — the
  gateway, tiers and bundle contract

## What this repository owns

- `gitops/hub-iam/iam/sources.yaml` — the chart sources (the published
  mojaloop helm chart repo, consumed at pinned per-branch pre-release
  versions, and the mojaloop/charts git tree)
- `gitops/hub-iam/values/iam.yaml` — the `mojaloop-iam` release's
  distribution values: the service registry (`global.authz`, one image+host
  per service), the resource vocabulary (`global.resourceNames`), Ory
  configuration and the IdP hosts
- `gitops/hub-iam/iam/roles.yaml` — the deployment's role document, validated
  against the composed catalog on rollout
- `gitops/hub-iam/iam/externalsecret-*.yaml` — Ory DSNs and secrets from
  Vault
- `gitops/hub-iam-config/*-authzdocument.yaml` — documents the deployment
  declares for surfaces whose images carry none: the Flux, Goldilocks and
  Hubble UIs, and the intapi mirror (a routing construct over the switch's
  services)
- `gitops/hub-app/routes/` — HTTPRoutes for those same third-party surfaces,
  delegating auth to Oathkeeper via ExternalAuth; every service whose chart
  this platform ships renders its own route instead (MCM, the portal, the
  testing toolkit, the settlement service)

## Hosts

One label per surface under the gateway wildcards:

| Surface | Host | Gateway |
| --- | --- | --- |
| Kratos public | `kratos.int.<domain>` | gw-int |
| Auth UI | `auth.int.<domain>` | gw-int |
| Hydra (machine tokens) | `hydra.ext.<domain>` | gw-ext |
| MCM UI | `mcm.int.<domain>` | gw-int |
| MCM API | `mcm-api.ext.<domain>` | gw-ext |
| Portal shell | `portal.int.<domain>` | gw-int |
| Portal micro-frontends | `portal-{iam,transfers,settlements,positions}.int.<domain>` | gw-int |
| Experience API | `portal-api.int.<domain>` | gw-int |
| Role administration API | `iam-api.int.<domain>` | gw-int |
| Reporting API | `reports-api.int.<domain>` | gw-int |
| Transfers reporting API | `transfers-api.int.<domain>` | gw-int |
| Settlement API | `settlements-api.int.<domain>` | gw-int |
| Testing toolkit | `ttk.int.<domain>` / `ttk-backend.int.<domain>` | gw-int |
| Flux / Goldilocks / Hubble | `flux.int` / `goldilocks.int` / `hubble.int` | gw-int |
| Operator machine API | `intapi.int.<domain>` | gw-intapi |

## Identities

The first identity is `${HUB_ADMIN_EMAIL}` (role `hub-admin`); on first
install it receives an invitation email and sets its password through the
auth UI, the same courier flow every other operator onboards through. A
DFSP's creation instantiates `dfsp-operator` (its invited human) and
`dfsp-client` (its machine client) for that participant. An operator-tool
machine client is admitted by creating its Hydra client and assigning the
client id the `intapi-client` role.
