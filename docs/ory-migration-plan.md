# Ory Full Stack Migration Plan (Remove Keycloak)

## Context

Dev environment — no production data, clean slate. Two-step approach:

- **Step 1**: Replace Keycloak with full Ory (add Hydra), keep MCM v3.7.4. Portal auth + PM4ML machine auth testable. DFSP provisioning and credentials rotation are known gaps.
- **Step 2**: Deploy MCM with PR#202 (Ory-native). Full provisioning, credentials rotation, and machine client auto-setup work.

---

## Step 1 — Replace Keycloak, add Hydra, keep MCM v3.7.4

### Files to delete

| File | Reason |
|---|---|
| `gitops/env-auth/keycloak/operator.yaml` | Keycloak operator gone |
| `gitops/env-auth/keycloak/keycloak.yaml` | Keycloak instance gone |
| `gitops/env-auth/keycloak/keycloak-metrics-service.yaml` | Keycloak metrics gone |
| `gitops/env-auth/keycloak/realm-dfsps.yaml` | Keycloak realm seed gone |
| `gitops/env-auth/keycloak/realm-hub-operators.yaml` | Keycloak realm seed gone |
| `gitops/env-auth/ory/kratos-role-webhook.yaml` | Was called on Keycloak OIDC login; no OIDC login anymore |
| `gitops/env-auth/routes/keycloak-httproute.yaml` | Keycloak ingress gone |
| `gitops/env-auth-config/keycloak/realm-dfsps.yaml` | Keycloak config gone |
| `gitops/env-auth-config/keycloak/realm-hub-operators.yaml` | Keycloak config gone |
| `gitops/env-app/routes/keycloak-ext-httproute.yaml` | Keycloak ext ingress gone |

### Files to add

| File | Content |
|---|---|
| `gitops/env-auth/ory/helmrelease-hydra.yaml` | Hydra HelmRelease (ory/hydra chart), MySQL DSN, admin + public ports, automigration |
| `gitops/env-auth/ory/externalsecret-hydra.yaml` | Hydra DSN secret, system secret, cookie secret from Vault |
| `gitops/env-auth/routes/hydra-httproute.yaml` | Expose `hydra.ext.${domain}` on ext gateway — PM4ML token endpoint (`/oauth2/token`) |

### Files to update

**`gitops/env-auth/kustomization.yaml`**
- Remove all `keycloak/*` entries
- Remove `ory/kratos-role-webhook.yaml`
- Remove `routes/keycloak-httproute.yaml`
- Add `ory/helmrelease-hydra.yaml`
- Add `ory/externalsecret-hydra.yaml`
- Add `routes/hydra-httproute.yaml`

**`gitops/env-auth-config/kustomization.yaml`**
- Remove `keycloak/realm-hub-operators.yaml`
- Remove `keycloak/realm-dfsps.yaml`

**`gitops/env-auth/ory/helmrelease-kratos.yaml`**
- Remove both OIDC providers (`hub-operators` + `dfsps` — both pointed at Keycloak)
- Enable `password` method
- Enable `recovery` method (magic-link — how hub operators get their initial login)
- Remove `selfservice.flows.login.after.oidc.hooks` (kratos-role-webhook call)
- Remove `selfservice.flows.registration.after.oidc.hooks`
- Change `selfservice.flows.logout.after.default_browser_return_url` away from Keycloak logout
- Change `subject_from: identity.traits.subject` → `identity.id`

**`gitops/env-auth/ory/helmrelease-oathkeeper.yaml`**
- JWT authenticator `jwks_urls`: replace Keycloak URL → `http://hydra-public.ory.svc.cluster.local:4444/.well-known/jwks.json`
- JWT authenticator: add `trusted_issuers` for Hydra public URL

**`gitops/env-app/mcm/helmrelease.yaml`**
- `api.keycloak.enabled: false`
- `api.keycloak.autoCreateAccounts: false`
- `ui.loginProvider: kratos`
- `ui.oauth.enabled: false`
- `ui.logoutUrl` → Kratos native logout (`/kratos/self-service/logout/browser`)

**`gitops/env-app/mcm/oathkeeper-rules.yaml`**
- All pm4mlapi rules: change JWT `jwks_urls` from Keycloak → Hydra (same URL as above)

**`gitops/env-app/routes/keycloak-ext-httproute.yaml`** (kustomization entry)
- Remove from `gitops/env-app/kustomization.yaml`

### Test criteria

- [ ] Hub operator can log in via Kratos password (recovery magic-link to set password)
- [ ] Portal loads session correctly (`/kratos/sessions/whoami` returns identity)
- [ ] Oathkeeper `cookie_session` rules pass through to MCM (GET /api/dfsps returns 200)
- [ ] Keto permission checks still work (hub operator sees all DFSPs)
- [ ] PM4ML can get a token from Hydra (`/oauth2/token` with `client_credentials`)
- [ ] PM4ML JWT is accepted by Oathkeeper on ext gateway (GET /pm4mlapi/dfsps returns 200 or 403 depending on Keto tuple)
- [ ] DFSP create from portal succeeds (no Keycloak call, MCM just writes to DB)
- [ ] `/api/dfsps/{id}/credentials` returns error (known gap — expected until Step 2)

### Known gaps after Step 1

- New DFSP machine clients: no Hydra client auto-created (manual only until Step 2)
- `/api/dfsps/{id}/credentials` — `CredentialsService` calls Keycloak unconditionally, fails

---

## Step 2 — Deploy MCM PR#202 (full Ory, clean Keto model)

Single coordinated Flux commit — Keto namespace wipe + new MCM + new Oathkeeper rules must land together.

### Files to delete

| File | Reason |
|---|---|
| `gitops/env-auth/ory/helmrelease-bof.yaml` | BOF manages old `role`/`permission` namespaces — replaced by OPL |
| `gitops/env-auth/ory/keto-batch-auth.yaml` | OR-check proxy used by old rules — OPL handles it in Keto directly |
| `gitops/env-auth/ory/helmrelease-selfservice-ui.yaml` | Review: selfservice UI tied to old OIDC flow; may be replaced by finance-portal or dropped |
| `gitops/env-app/ory-rbac-role-permissions.yaml` | MojaloopRole CRDs — BOF-owned, meaningless without BOF |

### Files to add

| File | Content |
|---|---|
| `gitops/env-auth/ory/iam-bootstrap-job.yaml` | K8s Job that seeds `Hub:{hub}#admins@{hub-admin-kratos-id}` into Keto on startup, before MCM starts |

### Files to update

**`gitops/env-auth/kustomization.yaml`**
- Remove `ory/helmrelease-bof.yaml`
- Remove `ory/keto-batch-auth.yaml`
- Remove `ory/helmrelease-selfservice-ui.yaml` (if dropped)
- Add `ory/iam-bootstrap-job.yaml`

**`gitops/env-auth/ory/helmrelease-keto.yaml`**
- Replace namespaces: remove `role`/`permission`/`participant`, add `Hub`/`Dfsp`/`User`
- Add `extraVolumes` ImageVolume mounting `permissions/mcm.keto.ts` from the MCM image (OPL file)
- Clean DB — dev env, just wipe and remigrate

**`gitops/env-auth/ory/helmrelease-oathkeeper.yaml`**
- Header mutator `X-Roles` template: change from `identity.traits.roles` → `identity.metadata_public` role + dfspId pattern (matches PR#202 identity shape)
- Header mutator `X-DFSP-ID`: from `identity.metadata_public.dfspId`

**`gitops/env-auth/ory/helmrelease-kratos.yaml`**
- Identity schema: remove `roles` trait (roles now live in Keto/Hydra, not Kratos traits)
- Add second identity schema `participant-user` if we want the two-schema model (hub-operator vs participant-user)

**`gitops/env-app/mcm/helmrelease.yaml`**
- Bump image to PR#202 version
- Add `api.hydra.adminUrl`, `api.kratos.adminUrl`
- Add env: `IAM_ENABLED=true`, `KETO_HUB_OBJECT=${hub_participant_name}`, role prefix config
- Remove remaining Keycloak/openid leftovers

**`gitops/env-app/mcm/oathkeeper-rules.yaml`**
- Full replacement with the 14 rules from `permissions/oathkeeper-rules.yml` in PR#202
- New model: `Hub`/`Dfsp`/`User` namespaces, both `cookie_session` + `jwt` on all routes, no `keto-batch-auth`

**`gitops/env-app/kustomization.yaml`**
- Remove `ory-rbac-role-permissions.yaml`

### Test criteria

- [ ] Keto starts with new namespaces (Hub/Dfsp/User) and OPL mounted
- [ ] Bootstrap job seeds Hub admin tuple before MCM is ready
- [ ] Hub operator login still works (Kratos session, same as Step 1)
- [ ] Hub operator can create a new DFSP — triggers Hydra client + Kratos identity + Keto tuple provisioning
- [ ] Newly created DFSP admin receives magic-link email and can set password
- [ ] DFSP admin can log in and sees only their own DFSP in portal
- [ ] PM4ML can get `client_credentials` token from Hydra (auto-provisioned client)
- [ ] PM4ML token accepted by Oathkeeper on ext gateway with new Hub/Dfsp Keto checks
- [ ] `/api/dfsps/{id}/credentials` works (Hydra client secret rotation via `DfspIamService`)
- [ ] Hub admin sees all DFSPs; DFSP member sees only their own

---

---

## Feature Parity Status (as of 2026-06-29)

| # | Feature | Keycloak behaviour | Ory status | Notes |
|---|---------|-------------------|------------|-------|
| 1 | Hub admin login — Finance Portal | Keycloak SSO, browser redirect | ✅ Done | Kratos `cookie_session`, tested |
| 2 | Hub admin login — MCM | Keycloak SSO, browser redirect | ✅ Done | Kratos `cookie_session`, tested |
| 3 | Finance Portal — Transfers | Keycloak role check | ✅ Done | Keto `permission:transferApi#granted`, tested |
| 4 | Finance Portal — Settlements / Positions | Keycloak role check | ✅ Done | Same Keto model, not explicitly re-tested |
| 5 | Finance Portal — Roles/IAM page | `role-assignment-service` called Keycloak admin API to list/assign user roles | ❌ Not done | Service disabled (crashes without Keycloak). Requires upstream code change in fin-portal to call Kratos admin API instead. Deferred. |
| 6 | Finance Portal — Users page | Same service as #5, listed Keycloak users | ❌ Not done | Same blocker as #5 |
| 7 | MCM hub admin — DFSP list | Keycloak role claim check | ✅ Done | Oathkeeper checks `permission:dfspList#granted`, tested |
| 8 | MCM hub admin — DFSP create | MCM creates DB record; Keycloak admin API creates user | ✅ Done | Full IAM chain: Hydra client + Kratos identity + Keto tuples, tested |
| 9 | DFSP invitation email — delivery | Keycloak sent "Set up account" email | ✅ Done | Kratos courier sends via configured SMTP (Gmail) |
| 10 | DFSP invitation email — template/content | "Welcome, set up your account" branding | ❌ Wrong | Kratos sends stock "Recover access to your account" template. No custom template configured. Needs custom Kratos email templates. |
| 11 | DFSP admin — follow invitation link, set password | Keycloak "required actions" page, direct password form | ❌ Broken | URL points to `https://auth.int.${domain}/ui/recovery` (Ory self-service UI). Ory reuses the recovery flow for invitations — UX copy and flow are wrong for first-time account setup. Custom templates + post-recovery redirect needed. |
| 12 | DFSP admin login — MCM | Keycloak OIDC password grant | ❌ Blocked by #11 | DFSP admin cannot set a password yet, so cannot log in |
| 13 | PM4ML machine client — OAuth2 token (client credentials) | Keycloak client credentials grant | ⚠️ Partial | Hydra OAuth2 client is auto-created on DFSP onboarding. Client secret returned by MCM `/credentials` endpoint. Hydra token endpoint live. End-to-end PM4ML flow untested. |
| 14 | MCM — DFSP admin scoped access (per DFSP) | Keycloak `dfsp:{id}` role claim | ⚠️ Partial | Oathkeeper rules still check `role:dfsp:{id}#member` (old BOF model). PR#202 writes `Dfsp:{id}#members` tuples (new model). New Oathkeeper rules for `Dfsp` namespace not yet written. Both models coexist. |
| 15 | MCM — PM4ML API (JWT auth) | Keycloak JWT | ⚠️ Partial | Oathkeeper JWT rules configured for Hydra-issued tokens. Depends on #13 working end-to-end. |
| 16 | MCM — DFSP credential rotation | Keycloak client secret rotation | ⚠️ Partial | `DfspIamService.rotateDfspClientCredentials()` exists in PR#202. API endpoint exists but untested. |
| 17 | MCM — Hub server cert / endpoint management | No auth change | ✅ Done | Oathkeeper rules cover these, unchanged |
| 18 | Session logout — Finance Portal | Keycloak logout + `post_logout_redirect_uri` | ✅ Done | Kratos logout browser flow configured |
| 19 | Session logout — MCM | Keycloak logout | ✅ Done | Configured |
| 20 | Hub admin Keto role seeding (BOF model) | Keycloak admin realm roles | ✅ Done | `keto-hub-admin-bootstrap` Job seeds all BOF `role:*#member` tuples |
| 21 | Hub admin `hub-admin` trait (MCM DFSP list filter) | Keycloak realm role → JWT claim | ✅ Done | Kratos identity `traits.roles: ["hub-admin"]`, patched by bootstrap Job |
| 22 | Hub `Hub:{hub}#admins` seeding (PR#202 Keto model) | N/A — new requirement from PR#202 | ❌ Missing | `KetoClient` creates `Dfsp:{id}#parent@Hub:{hub}` tuples but `Hub:{hub}#admins@{hub_admin_email}` is never seeded. Needed for the new `Dfsp` namespace permission traversal to function. |
| 23 | Keycloak admin console | Available for manual admin ops | N/A | Ory has no web admin UI. Admin via API only (`kratos-admin`, `hydra-admin`). Not a blocker. |
| 24 | Email — `from` address / branding | Keycloak realm configured sender name and address | ❌ Not set | Courier sends from `no-reply@ory.kratos.sh`. No custom `from` address configured in Kratos courier. |

### Summary

| Category | Count |
|----------|-------|
| ✅ Done | 11 (items 1–4, 7–9, 17–21) |
| ⚠️ Partial | 4 (items 13–16) |
| ❌ Not done / broken / missing | 9 (items 5, 6, 10, 11, 12, 22, 23, 24) |

**Critical path to full parity:** fix DFSP admin invitation flow (items 10, 11 → unblocks 12 → unblocks 13–16), then Finance Portal IAM (items 5, 6 — requires upstream mojaloop code change).

---

## Open questions before starting

1. **PR#202 merge status** — Step 2 depends on it being merged and a chart version published. What's the timeline?
2. **Hydra DB** — does Hydra get its own MySQL schema or a shared one? (Keto and Kratos already have dedicated schemas.)
3. **selfservice-ui** — keep it for Step 1 (hub operator login UI), drop in Step 2 in favour of finance-portal's own login UI, or keep both?
4. **PM4ML test client for Step 1** — since there's no auto-provisioning yet, we'll need one manually created Hydra client to validate the machine auth path. Who creates it (manual `hydra clients create` or a bootstrap ConfigMap)?
