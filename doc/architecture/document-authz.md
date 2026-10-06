# Document-composed authorization

Authorization is derived from the services' OpenAPI documents. Each HTTPRoute
keys the backends it sends traffic to with a permission prefix
(`iam.mojaloop.io/<backend>.service`); a backend serves its own document, or
the route names an `AuthzDocument` for it (`iam.mojaloop.io/<backend>.schema`).
The IAM reads every keyed backend's document and composes them into the
deployment's gateway rules, Keto model and permission catalog. Oathkeeper and
Keto reload the composed artifacts in place; no hand-written access rules or
permission tuple lists exist in this repository.

The model and its rules are documented with the chart (mojaloop/helm):

- `mojaloop-iam/docs/permissions-guide.md` — the guide: protecting a service,
  roles, what happens when something is wrong
- `mojaloop-iam/docs/permission-model.md` — permissions, roles, scoping,
  resource names
- `mojaloop-iam/docs/discovery.md` — how a route's document is found
- `mojaloop-iam/docs/gateway-authz-architecture.md` — the gateway, tiers and
  bundle contract

## What this repository owns

- `gitops/hub-iam/iam/sources.yaml` — the chart sources
- `gitops/hub-iam/values/ory/iam.yaml` — the `mojaloop-iam` release's
  distribution values: the resource vocabulary (`global.resourceNames`), Ory
  configuration and the IdP hosts
- `gitops/hub-iam/iam/roles.yaml` — the deployment's role document. A role
  goes live once every service it names is routed; until then it waits, listed
  under `pending` in the IAM's `/state`
- `gitops/hub-iam/iam/externalsecret-*.yaml` — Ory DSNs and secrets from
  Vault
- the permission prefix of each service this platform ships, set in its
  release values as `authz.service` (per surface for MCM: `api.authz`,
  `ui.authz`); the charts render the route annotations from it
- `gitops/hub-app/routes/` — HTTPRoutes for surfaces whose charts render none,
  each beside the `AuthzDocument` it names: the Flux, Goldilocks and Hubble
  UIs, and the intapi mirror

## Permission prefixes

| Surface | Prefix | Document |
| --- | --- | --- |
| MCM API | `mcm` | served |
| MCM UI | `mcmUi` | chart |
| Role administration API | `iam` | served |
| Reporting API | `reports` | served |
| Transfers reporting API | `trxreporting` | served |
| Experience API | `ledger` | served |
| Settlement API | `settlement` | served |
| Portal shell / micro-frontends | `portalShell`, `portalRoles`, `portalTransfers`, `portalSettlements`, `portalPositions` | chart |
| Testing toolkit UI / backend | `ttkUi` / `ttkBackend` | chart / served |
| Flux / Goldilocks / Hubble | `fluxUi` / `goldilocksUi` / `hubbleUi` | `gitops/hub-app/routes` |
| Operator machine API | `lookup`, `quotes`, `transfers`, `transactionRequests`, `intapiSettlements` | `gitops/hub-app/routes` |

The intapi route dispatches by path to five services, so each is keyed with
its own prefix over one document. Central settlement also answers on its own
route as `settlement`, with the document it serves, so its intapi mount has a
prefix of its own.

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
