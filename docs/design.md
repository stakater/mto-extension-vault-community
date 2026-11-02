# Design

**Status:** proposed; every story is Draft. Baseline Vault Community 2.1.1 and
VCO v1.0.3. Facts are cited to `vault-community-baseline.md` by row (e.g.
**N2**); decisions to ADRs.

This extension is a **delta from `mto-extension-vault-enterprise`**, which is
built and tested. Everything not named here — the workload annotation
contract, tiers, the dot-joined name families, the `vault-apps` index, ESO
delivery, error ConfigMaps, the `tenantValues` mechanism, the uninstall order —
is the Enterprise extension's, unchanged (ADR-0001). Read its
`charts/README.md` first.

## 1. Scope

Every Multi-Tenant Operator tenant gets a secret scope in one shared Vault
Community: its own KV mount, a policy and login role per annotated
ServiceAccount, SSO in four tiers, opt-in sharing inside the tenant and across
tenants, delivery through External Secrets Operator. Phase 3: Transit and PKI,
as the Enterprise extension adds them. Non-goals: see `vision.md`.

## 2. Architecture

Two Helm charts rendering VCO CRs through Template Operator v2 — the
Enterprise extension's shape (ADR-0001). See `diagrams.md`.

| Chart | Installed | Renders |
|---|---|---|
| `mto-extension-vault-community-bootstrap` | once per cluster, by Helm | the parent Template and TemplateInstance; the shared mount `shared/kv`; the shared auth mounts `kubernetes/workloads` and (with SSO) `oidc/sso` with their config; **per Tenant**, the tenant mount `<tenant>/kv`; the skipped-tenants ConfigMap; the VCO login ServiceAccount |
| `mto-extension-vault-community` | never by hand; pulled per tenant | slice `core`: policies and Kubernetes auth roles per annotated ServiceAccount, SSO policies and OIDC roles per tier, `vault-config-<sa>` and `vault-apps` ConfigMaps; slice `eso`: SecretStores and ExternalSecrets |

The three differences from the Enterprise charts:

1. **No `Namespace` CR and no `targetNamespace`.** Every VCO CR targets root
   (V6).
1. **The tenant mount is `<tenant>/kv`, not `kv` inside `<tenant>/`.** The full
   request path is the same string Enterprise uses when the namespace is in the
   URL (`/v1/team-a/kv/data/...`).
1. **The auth mounts are shared, created once by the bootstrap chart**, not per
   tenant. Roles were already tenant-qualified by name (`kv.<tenant>.…`,
   `sso.<tenant>.…`), so no new name family is needed (ADR-0002).

## 3. What is rendered

For tenant `team-a`, ServiceAccount `web` in `team-a-api` at tier `editor`,
environment `dev`.

| VCO kind | Rendered by | Name | Vault object |
|---|---|---|---|
| `SecretEngineMount` | parent, per Tenant | `team-a-kv` | `team-a/kv/`, `kv-v2`, `listingVisibility: hidden` (V4) |
| `SecretEngineMount` | bootstrap, once | `shared-kv` | `shared/kv/` |
| `AuthEngineMount` + `KubernetesAuthEngineConfig` | bootstrap, once | `workloads` | `auth/kubernetes/workloads/` |
| `AuthEngineMount` + `JWTOIDCAuthEngineConfig` | bootstrap, once, with SSO | `sso` | `auth/oidc/sso/` |
| `Policy` | tenant chart, per ServiceAccount | `kv.team-a.team-a-api.web` | see below |
| `KubernetesAuthEngineRole` | tenant chart, per ServiceAccount | `kv.team-a.team-a-api.web` | on `kubernetes/workloads`, bound to `web` in `team-a-api`, policy of the same name, TTL ≤ 1 h |
| `Policy` + `KubernetesAuthEngineRole` | per export / import | `share.team-a.team-a-api.web.out.team-b` / `.in.team-b` | `shared/kv/data/dev/from-team-a/to-team-b/*` write / `from-team-b/to-team-a/*` read |
| `Policy` + `JWTOIDCAuthEngineRole` | per SSO tier | `sso.team-a.editor` | on `oidc/sso`, `bound_claims.groups: [team-a-editors]`, policy over `team-a/kv/` at that tier |
| ConfigMap | per ServiceAccount | `vault-config-web` | `VAULT_ADDR`, `VAULT_K8S_MOUNT=kubernetes/workloads`, `VAULT_K8S_ROLE`, `VAULT_KV_APP_PATH=team-a/kv/data/dev/team-a-api/web/`, `VAULT_KV_SHARED_OUT_PATH`, `VAULT_FROM_<NS>_PATH`, `VAULT_OUT_<PEER>_*`, `VAULT_IN_<PEER>_*`; **`VAULT_NAMESPACE` empty** |
| `SecretStore` (slice `eso`) | per ServiceAccount | `web-vault` | `path: team-a/kv`, `version: v2`, no `namespace`, Kubernetes auth with role `kv.team-a.team-a-api.web` |

The workload policy at `editor`:

```hcl
path "team-a/kv/data/dev/team-a-api/web/*"     { capabilities = ["create", "read", "update"] }
path "team-a/kv/metadata/dev/team-a-api/web/*" { capabilities = ["read", "list"] }
path "team-a/kv/data/dev/_shared/from-team-a-api/*" { capabilities = ["create", "read", "update"] }
path "team-a/kv/data/dev/_shared/from-team-a-api/" { capabilities = ["list"] }
# + read on each subscribed sibling's _shared/from-<ns>/*
```

The tiers' capabilities are the Enterprise extension's, unchanged.

**Not rendered:** VCO's own login (`auth/kubernetes`, role `vco-admin`, set up
once by a Vault admin), audit devices, the root token, quotas, any other
platform mount.

## 4. The scope check (ADR-0003)

Community Edition has one wall: the policy (P1). So every policy the tenant
chart renders is checked, deterministically, before it can exist:

| Rule | Why |
|---|---|
| every `path` in a tenant `t`'s policies starts with `t/kv/`, or is under `shared/kv/{data,metadata}/<env>/from-<x>/to-<y>/` with `t` ∈ {x, y} and the other side named in an annotation | nothing outside the tenant |
| the tenant segment is always followed by `/` before any wildcard; `*` appears only as the final character after a `/`; no `+` | `team-a*` would match `team-ab/` (P2) |
| no path under `sys/`, `auth/`, `identity/`, `cubbyhole/` | tenants never administer Vault (ADR-0004) |
| every Policy, role and ConfigMap name belongs to a family (`kv.` 4 parts, `share.` 6, `sso.` 3) whose second part is `t` | no tenant renders another tenant's or a platform object |

Enforced three times: in the chart's `_helpers.tpl` (a violating policy fails
the render, never rendered), in the render-test harness (`policyscope`,
mutation-tested), and, for the parent, by refusing tenant names that would
break it (§5).

## 5. Tenant names

The parent **skips** a Tenant, and lists it with the reason in ConfigMap
`mto-extension-vault-community-skipped-tenants`, when its name is:

- not a DNS label, or longer than 63 characters (as in Enterprise);
- `shared` (`parent.sharedTenantName`);
- a reserved Vault path: `sys`, `auth`, `identity`, `cubbyhole`;
- in `parent.reservedPaths` (default `secret`, `kv`, `pki`, `transit`,
  `database`, `ssh`, `totp`): the platform's own mount prefixes, which the
  parent can't read from Vault, so the platform lists them.

A name that collides with a mount the list misses fails in Vault (N3); VCO's
error reaches the parent TI's outputs (`secretEngineMountLastError`), and no
other tenant is affected.

## 6. VCO's login policy (ADR-0006)

VCO is the only identity that writes Vault configuration, and on Community
Edition it writes in the same namespace as everything else — including its own
policy. So its policy is narrowed **by name**, not by namespace:

```hcl
path "sys/mounts"                 { capabilities = ["read"] }
path "sys/mounts/+/kv"            { capabilities = ["create", "read", "update"] }  # no delete
path "sys/mounts/+/kv/tune"       { capabilities = ["create", "read", "update"] }
path "sys/auth"                   { capabilities = ["read"] }
path "sys/auth/kubernetes/workloads"      { capabilities = ["create", "read", "update", "sudo"] }
path "sys/auth/kubernetes/workloads/tune" { capabilities = ["create", "read", "update", "sudo"] }
path "sys/auth/oidc/sso"                  { capabilities = ["create", "read", "update", "sudo"] }
path "sys/auth/oidc/sso/tune"             { capabilities = ["create", "read", "update", "sudo"] }
path "auth/kubernetes/workloads/config"   { capabilities = ["create", "read", "update"] }
path "auth/kubernetes/workloads/role/kv.*"    { capabilities = ["create", "read", "update", "delete"] }
path "auth/kubernetes/workloads/role/share.*" { capabilities = ["create", "read", "update", "delete"] }
path "auth/oidc/sso/config"               { capabilities = ["create", "read", "update"] }
path "auth/oidc/sso/role/sso.*"           { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/kv.*"    { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/share.*" { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/sso.*"   { capabilities = ["create", "read", "update", "delete"] }
```

What this gives:

- VCO **can't rewrite its own policy** (`vco-admin`), `default`, or any
  platform policy: none starts with `kv.`, `share.` or `sso.`.
- VCO **can't edit its own login role**: it lives on `auth/kubernetes`, a
  different mount from the workloads' `auth/kubernetes/workloads`.
- VCO **can't delete a mount**: no `delete` on `sys/mounts/+/kv`. Deleting a
  tenant leaves its data (ADR-0005).
- `+` in `sys/mounts/+/kv` lets VCO create a `kv` mount under any one-segment
  prefix. That is the platform's trust in whoever can create VCO CRs in the
  config namespace — the same trust as on Enterprise. Open question 2 checks
  whether any VCO call needs `list` on the unnarrowed paths.

## 7. Lifecycle (ADR-0005)

As in the Enterprise extension, with the mount in the parent's place of the
`Namespace`:

| Event | Extension | Data |
|---|---|---|
| Tenant created | parent renders `<tenant>/kv` | — |
| Tenant gets its first labelled namespace | child TIs render | — |
| ServiceAccount annotated | policy, role, ConfigMap, ESO objects | — |
| Annotation removed, tier lowered | policy rewritten or removed, role removed | secrets stay |
| Last namespace unlabelled | child TIs go: every grant revoked | mount and secrets stay |
| Person leaves a group | nothing | no new SSO login; tokens expire within their TTL |
| Tenant deleted | grants revoked; mount CR stays `Terminating` (VCO's delete refused) | secrets stay until a Vault admin runs `vault secrets disable <tenant>/kv` and removes the finalizer |
| Tenant recreated with the same name | the mount is adopted | the old secrets come back — purge before reusing a name |

Shares live in `shared/kv/`, in neither tenant, so deleting a tenant never
deletes one; delete `from-<tenant>/` and `to-<tenant>/` there before a name is
reused.

## 8. Health and preflight

Inherited from the Enterprise extension: per-kind `<kind>Succeeded` and
`<kind>LastError` outputs on the child TIs (V5), ESO sync status on the `.eso`
TI, error ConfigMaps per ServiceAccount, the skipped-tenants ConfigMap.

Added for Community Edition:

| Check | How |
|---|---|
| the Vault is Community Edition | documented install check (`vault status` shows no licence); the e2e preflight asks the server and refuses Enterprise, the mirror of the Enterprise suite refusing Community. The charts call no Vault API themselves |
| the tenant mount exists per tenant | `secretEngineMountSucceeded` on the parent's outputs |
| VCO's policy is the narrowed one | documented install check; the e2e suite asserts VCO is refused a write to `sys/policy/vco-admin` |

## 9. Install requirements

- Vault Community Edition ≥ 2.0; 2.1.1 is the tested baseline.
- VCO ≥ v1.0.3, logging in with the policy in §6.
- Template Operator v2 ≥ 0.0.5; Multi-Tenant Operator labelling tenant
  namespaces `stakater.com/tenant`.
- External Secrets Operator when `parent.eso=enabled`.
- An OIDC identity provider for SSO, one client shared by every tenant.
- Only the Multi-Tenant Operator and cluster admins may set
  `stakater.com/tenant` on a namespace (the trust boundary, unchanged).

## 10. What Community Edition can't isolate (documented, not hidden)

| Shared by every tenant | Consequence | Enterprise or OpenBao |
|---|---|---|
| one root namespace | policy is the only wall; a policy written by hand outside the extension can still cross tenants | a namespace per tenant |
| one audit log (O1) | per-tenant audit is a downstream filter on `<tenant>/` | filtered audit devices (Enterprise) |
| one set of auth methods | no per-tenant auth configuration or token settings beyond the role | per-namespace auth |
| one identity store (N5) | entities and groups are global objects, readable only by Vault admins | per-namespace identity |
| quotas by source address only (O2) | no per-tenant fairness | lease-count quotas (Enterprise) |
| no delegated administration | tenants can never manage policies or mounts — by design here (ADR-0004) | namespace admins |
