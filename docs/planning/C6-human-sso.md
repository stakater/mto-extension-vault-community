# C.6 — Human SSO in four roles

Story: `docs/roadmap.md` C.6 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-ISO-6, AC-ISO-9, AC-ACC-1..4 (people), AC-ACC-6.

## Why (one paragraph)

Workloads have access; people do not. A tenant's developers need to sign in
to Vault with their identity-provider group and get their tenant's secrets at
their role — and nothing in another tenant, and never Vault administration.
This story ports the Enterprise SSO templates to a per-tenant OIDC mount
`auth/<tenant>/oidc/sso`, and settles the open item from C.0: how the
identity provider allows a callback per tenant mount.

## Governing constraints

- ADR-0007: the tenant's OIDC mount is `auth/<tenant>/oidc/sso`.
- ADR-0003, design §4: an SSO policy stays in `<tenant>/kv/…` (and may list
  `<tenant>/kv/metadata`); an SSO role binds exactly its tenant's group from
  the configured pattern, with string claims. Enterprise's
  `sso.tenantRoleMapping.fallback` (a role with no bound claims) is refused.
- ADR-0004: no role administers Vault (AC-ISO-9).
- A3: one IdP client serves every tenant; the audience is the client ID.
- Design §9 VERIFY: each tenant's mount has its own UI callback
  (`/ui/vault/auth/<tenant>/oidc/sso/oidc/callback`). Enterprise avoids this
  with `namespace_in_state`; here the IdP client must allow one redirect URI
  per tenant, or a wildcard where the IdP supports one.

## Design

Tenant chart, ported from Enterprise:

- `templates/06-oidc-auth.yaml`: `AuthEngineMount <tenant>-oidc` (`path:
  <tenant>/oidc`, `name: sso`, type `oidc`) and `JWTOIDCAuthEngineConfig
  <tenant>-oidc-config` (`path: <tenant>/oidc/sso`), with the one shared IdP
  client.
- `templates/07-sso-policies.yaml`: per entry of `sso.roles`, Policy and
  `JWTOIDCAuthEngineRole` `sso.<tenant>.<role>`, the policy over
  `<tenant>/kv/…` at the role's capabilities, through the scope check; the
  role bound to exactly the group `sso.tenantGroupTemplate` gives.
  `tenantRoleMapping.fallback` other than `deny` fails the render.
- `sso.allowedRedirectUris` entries may hold `{tenant}`, replaced with the
  tenant's name: one install-wide value gives each tenant's role its own UI
  callback, `https://<vault>/ui/vault/auth/{tenant}/oidc/sso/oidc/callback`.
  The CLI's `http://localhost:8250/oidc/callback` is the same for every mount.

Lab: `hack/lab/keycloak.yaml` and `keycloak-setup-job.yaml` ported (realm
`mto`, groups `<tenant>-<role>s`, users alice, bob, carol, dave, erin). Dex
from its public chart with a config the Makefile builds from Secrets (the Dex
Config Operator chart is not readable from ghcr.io for this lab, see C.0):
one Keycloak connector and one static client `vault`, whose redirect URIs list
the CLI callback and one UI callback per lab tenant — Dex has no wildcard.

## Tests (red first)

Render: `ssoredirect` (an empty list fails; `{tenant}` is replaced per
tenant), `ssorootlist` (every SSO policy lists `<tenant>/kv/metadata`),
`ssoroles` (a non-DNS role and `fallback` fail), `ssofallback` (a fallback
mapping fails the render), `ssoaudience` (every role accepts exactly the
client ID), `mountagree` for the OIDC mount, `toggles` and `falsestring` for
`sso.enabled`, `namecollide` across families (tenant `sso`'s own Policy vs
tenant `acme`'s SSO Policy), `removedkeys` (tenant half), `contract` with the
SSO delta lines removed.

Live: Keycloak users log in through Dex at their tenant's mount with their
group's role; a group gives only its role and only in its tenant; the viewer
reads and can't write; audit-read lists and reads nothing; only admin
destroys; the admin can't write a policy, mount or role (AC-ISO-9); a user
removed from the group can't log in again (AC-ACC-6); the admission cases
run with the issuer.

Mutation: bind every SSO role also to the viewers' group (bob's editor login
must be refused); give audit-read data read.

## Out of scope

Vault UI screenshots (the Enterprise suite's browser-runner image is private);
per-tenant IdP clients.

## Done means

The roadmap Done line; `make verify` green; e2e green with the SSO steps;
`charts/README.md` "Human SSO" written with the redirect URI rule; design §9's
VERIFY resolved; story marked ✅ with this doc linked.
