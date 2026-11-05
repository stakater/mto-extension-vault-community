# Design

**Status:** built: Phases 1 and 2 (C.1 to C.11, and C.17, the review's
fixes) are done and proven on a live Vault Community 2.1.1 with VCO v1.0.3
(`make e2e-kind`); Phase 3 is Draft. Baseline Vault Community 2.1.1 and
VCO v1.0.3. Facts are cited to `vault-community-baseline.md` by row (e.g.
**N2**); decisions to ADRs. Verified on a live install in story C.0
([`spikes/c0-findings.md`](spikes/c0-findings.md), questions cited as **Q13**).

This extension is a **delta from `mto-extension-vault-enterprise`**, which is
built and tested. Everything not named here — the workload annotation
contract, roles, the dot-joined name families, the `vault-apps` index, ESO
delivery, error ConfigMaps, the `tenantValues` mechanism, the uninstall order —
is the Enterprise extension's, unchanged (ADR-0001). Read its
`charts/README.md` first.

## 1. Scope

Every Multi-Tenant Operator tenant gets a secret scope in one shared Vault
Community: its own KV mount, a policy and login role per annotated
ServiceAccount, SSO in four roles, opt-in sharing inside the tenant and across
tenants, delivery through External Secrets Operator. Phase 3: Transit and PKI,
as the Enterprise extension adds them. Non-goals: see `vision.md`.

## 2. Architecture

Two Helm charts rendering VCO CRs through Template Operator v2 — the
Enterprise extension's shape (ADR-0001). See `diagrams.md`.

| Chart | Installed | Renders |
|---|---|---|
| `mto-extension-vault-community-bootstrap` | once per cluster, by Helm | the parent Template and TemplateInstance; the shared mount `shared/kv`; **per Tenant**, the tenant mount `<tenant>/kv`; the skipped-tenants ConfigMap; the VCO login ServiceAccount; the admission policies on VCO CRs (§4) |
| `mto-extension-vault-community` | never by hand; pulled per tenant | slice `core`: the tenant's auth mounts `auth/<tenant>/kubernetes/workloads` and (with SSO) `auth/<tenant>/oidc/sso` with their config, policies and Kubernetes auth roles per annotated ServiceAccount, SSO policies and OIDC roles per role, `vault-config-<sa>` and `vault-apps` ConfigMaps; slice `eso`: SecretStores and ExternalSecrets |

The three differences from the Enterprise charts:

1. **No `Namespace` CR and no `targetNamespace`.** Every VCO CR targets root
   (V6).
1. **Every Vault path is the Enterprise path with the tenant prefix.**
   Enterprise's `kv/`, `auth/kubernetes/workloads/` and `auth/oidc/sso/`
   inside the namespace `<tenant>/` become `<tenant>/kv/`,
   `auth/<tenant>/kubernetes/workloads/` and `auth/<tenant>/oidc/sso/` in
   root; the shared namespace's `kv/` becomes `shared/kv/`, and the share
   roles live on each tenant's own `auth/<tenant>/kubernetes/workloads/`, so a
   share login uses `VAULT_K8S_MOUNT` like any other (ADR-0007). For secrets
   the request path
   is the same string Enterprise uses with the namespace in the URL
   (`/v1/team-a/kv/data/...`). The tenant chart renders the tenant's auth
   mounts, as Enterprise's does, so offboarding disables them and revokes
   every token issued through them (A6, Q17). One shared auth mount can't do
   that, and in root it can't be `auth/kubernetes/workloads` either: Vault
   refuses an auth mount nested under VCO's login mount (N7).
1. **The scope check also runs at admission.** On Enterprise the Vault
   namespace bounds what VCO writes; on Community nothing in Vault does —
   VCO's policy bounds names and mount types, not what a policy grants (P6,
   Q16). So the bootstrap chart installs admission policies that refuse a VCO
   CR in `vault-config` of a kind the extension does not render, with a
   `spec.connection` or another `spec.authentication`, whose content leaves
   its tenant's scope, or that Template Operator writes for a TemplateInstance
   outside `vault-config` (§4, ADR-0003, ADR-0008).

Each role also binds its namespace by name **and** tenant label (Q13). That is
not a difference by intent: the Enterprise chart binds by name only and has
the same gap; the fix belongs in both (story C.19).

## 3. What is rendered

For tenant `team-a`, ServiceAccount `web` in `team-a-api` with role `editor`,
environment `dev`.

| VCO kind | Rendered by | Name | Vault object |
|---|---|---|---|
| `SecretEngineMount` | parent, per Tenant | `team-a-kv` | `team-a/kv/`, `kv-v2`, `listingVisibility: hidden` (V4) |
| `SecretEngineMount` | parent, once | `shared-kv` | `shared/kv/` |
| `AuthEngineMount` + `KubernetesAuthEngineConfig` | tenant chart, per tenant | `team-a-kubernetes` | `auth/team-a/kubernetes/workloads/` |
| `AuthEngineMount` + `JWTOIDCAuthEngineConfig` | tenant chart, per tenant, with SSO | `team-a-oidc` | `auth/team-a/oidc/sso/` |
| `Policy` | tenant chart, per ServiceAccount | `kv.team-a.team-a-api.web` | see below |
| `KubernetesAuthEngineRole` | tenant chart, per ServiceAccount | `kv.team-a.team-a-api.web` | on `team-a/kubernetes/workloads`, bound to `web` in the namespace selected by `kubernetes.io/metadata.name: team-a-api` and `stakater.com/tenant: team-a` (V10), policy of the same name, token TTL 1 h, renewable to 4 h (`token.ttl`, `token.maxTTL`) |
| `Policy` + `KubernetesAuthEngineRole` | per export / import | `share.team-a.team-a-api.web.out.team-b` / `.in.team-b` | on `team-a/kubernetes/workloads` (the tenant's own mount, ADR-0007); `shared/kv/data/dev/from-team-a/to-team-b/*` write / `from-team-b/to-team-a/*` read |
| `Policy` + `JWTOIDCAuthEngineRole` | per SSO role | `sso.team-a.editor` | on `team-a/oidc/sso`, `bound_claims.groups: [team-a-editors]`, policy over `team-a/kv/` at that role |
| ConfigMap | per ServiceAccount | `vault-config-web` | `VAULT_ADDR`, `VAULT_K8S_MOUNT=team-a/kubernetes/workloads`, `VAULT_K8S_ROLE`, `VAULT_KV_APP_PATH=team-a/kv/data/dev/team-a-api/web/`, `VAULT_KV_SHARED_OUT_PATH`, `VAULT_FROM_<NS>_PATH`, `VAULT_OUT_<PEER>_*`, `VAULT_IN_<PEER>_*`; **`VAULT_NAMESPACE` empty** |
| `SecretStore` (slice `eso`) | per ServiceAccount | `web-vault` | `path: team-a/kv`, `version: v2`, no `namespace`, Kubernetes auth on `team-a/kubernetes/workloads` with role `kv.team-a.team-a-api.web` |
| `ValidatingAdmissionPolicy` and binding (not VCO) | bootstrap, once | `…-vco-kinds`, `…-vco-origin`, `…-vco-scope`, `…-vco-cluster` | none: Kubernetes admission on the VCO CRs in `vault-config` (§4) |

The workload policy at `editor`:

```hcl
path "team-a/kv/data/dev/team-a-api/web/*"     { capabilities = ["create", "read", "update", "patch", "list"] }
path "team-a/kv/metadata/dev/team-a-api/web/*" { capabilities = ["create", "read", "update", "patch", "list"] }
path "team-a/kv/data/dev/_shared/from-team-a-api/*"     { capabilities = ["create", "read", "update", "patch", "list"] }
path "team-a/kv/metadata/dev/_shared/from-team-a-api/*" { capabilities = ["create", "read", "update", "patch", "list"] }
# + read and list on each subscribed namespace's _shared/from-<ns>/*
```

The roles' capabilities are the Enterprise extension's, unchanged: this is the
Enterprise chart's policy with every path starting at the tenant mount
(`spikes/c0/tenants.yaml`, run in C.0). Every stanza is one line: the scope
check reads each path (§4).

**Not rendered:** VCO's own login (`auth/kubernetes`, role `vco-admin` bound to
the ServiceAccount `vco-admin` in `vault-config` only, set up once by a Vault
admin, V13), audit devices, the root token, quotas, any other platform mount.

## 4. The scope check (ADR-0003)

Community Edition has one wall: the policy (P1). And VCO, which writes every
policy, is bounded by its own Vault policy in names and mount types only (P6).
So every Vault object the extension asks VCO for is checked, deterministically,
before it can exist:

| Rule | Why |
|---|---|
| a VCO CR in `vault-config` is one of the seven kinds the extension renders, has a spec and no `spec.connection`, and logs in with the install's `vco.authPath`, `vco.role` and `vco.serviceAccount` and no Vault namespace | VCO's token is root-equivalent: another kind (an `AppRoleAuthEngineRole` on `auth/<t>/…/role/kv.*`) would write unchecked, and a `spec.connection` would send VCO's login JWT to another host, which could replay it here |
| every Policy and role name is in a family (`kv.` 4 parts, `share.` 6, `sso.` 3), every part a DNS label, and its second part is `t` | no tenant renders another tenant's or a platform object |
| a policy has no `type`, and is one-line `path "…" { capabilities = [...] }` stanzas, with no `sudo` | the check sees every path; a JSON body or a split stanza can't hide one; with a `type` VCO would write `sys/policies/acl/…` instead |
| every path of `kv.t.…` and `sso.t.…` is under `t/kv/{data,metadata,delete,undelete,destroy}/<env>/`; an SSO role may also list `t/kv/metadata` | nothing outside the tenant, and not the mount's `config` (ADR-0004) |
| every path of `share.t.<ns>.<sa>.out.p` is `shared/kv/{data,metadata}/<env>/from-t/to-p/*`; of `….in.p`, `…/from-p/to-t/*`, with read and list only | a share in its own direction, to its named peer |
| the tenant segment is always followed by `/` before any wildcard; `*` appears only as the final character after a `/`; no `+` | `team-a*` would match `team-ab/` (P2) |
| a workload role binds only its own policy, its tenant's mount `t/kubernetes/workloads` (for `share.` roles too), its own ServiceAccount, and its namespace by `kubernetes.io/metadata.name` AND `stakater.com/tenant: t` | a role can't hand out another tenant's policy, and a namespace name reused by another tenant gets nothing (Q13) |
| an SSO role binds only its own policy, `t/oidc/sso`, and exactly the tenant's group from the configured pattern, with string claims; every pattern holds `{tenant}` once, and (tenant, role) → group is one to one: no two tenants, and no two roles of one tenant, share a group (checked at install) | no group of one tenant gets another's role; no group gets a role in every tenant, or two roles of one; no role without bound claims (Enterprise's `fallback` is refused) |
| a mount is `t/kv` of type `kv`, `t/kubernetes/workloads` or `t/oidc/sso`, with no audit or header settings; an auth config names this cluster's API and CA and the install's IdP | VCO is asked for nothing else |

Enforced four times:

1. in the chart's `_helpers.tpl`: a policy that leaves its scope fails the
   render (`vault.assertPolicyScope`), and the roles are built from the same
   names, mount and selector;
1. in the render-test harness (`policyscope` on the `all` render and on each
   slice, `union` content equality, `scopebranches` with a bad input per
   branch of the helper);
1. by the parent, refusing tenant names that would break it (§5);
1. **at the API server**, by four ValidatingAdmissionPolicies on the
   `redhatcop.redhat.io` objects in `vault-config`, which the bootstrap chart
   installs (spike: [`c0/q18-admission.yaml`](spikes/c0/q18-admission.yaml),
   34 of 34 cases):
    - `kinds`: the seven kinds only, with a spec, no `spec.connection`, the
      install's `spec.authentication`;
    - `origin`: an object Template Operator renders must come from a
      TemplateInstance in `vault-config`. A Template in a tenant namespace can
      name `namespace: vault-config`, and Template Operator applies it with its
      own rights (T2, Q18b). Template Operator stamps every object with its
      source namespace, so the check reads that label for every writer, and
      a wrong `templateOperator.*` can't switch it off;
    - `scope`: the rules above, for every writer — the charts, Template
      Operator, a person;
    - `cluster`: a Kubernetes auth config names this cluster's API, and a CA
      equal to `kube-root-ca.crt` (V11).

   Failure policy `Fail`; a deletion is never blocked: VCO's finalizer
   updates of an object being deleted pass while its spec is unchanged, or
   while neither side has a spec (a CR written with the policies off), and a
   spec changed, removed or added during a deletion is checked like any
   other. `make verify` runs the CEL offline, through k8s.io/apiserver's own
   admission plugin, against the 77 cases of `hack/lab/admission-cases.sh`,
   each policy on its own, and compiles every expression as a Kubernetes 1.30
   API server does; the e2e suite runs 74 of them on the lab, the update and
   deletion cases on an old object created for real and held in deletion by
   a finalizer. The 3 whose old object admission refuses (a spec out of
   scope, or no spec) run offline only.

The first three catch the extension's own mistakes; the fourth is the wall,
because it holds for anyone who can write to `vault-config`. Every guard
listed in `hack/mutation_tests.py` is mutation-tested: weakened, it must fail
the check the list names (`make mutation-test`).

## 5. Tenant names

The parent **skips** a Tenant, and lists it with the reason in ConfigMap
`mto-extension-vault-community-skipped-tenants`, when its name is:

- not a DNS label, or longer than 29 characters: the child TemplateInstance
  `mto-extension-vault-community-<tenant>.eso` is a label value, which caps at
  63, and the tenant chart refuses the same budget. The budget is set before
  the first release; lowering it later would skip tenants that rendered
  before, and they would lose their access (not their data);
- `shared` (`parent.sharedTenantName`);
- a reserved Vault path: `sys`, `auth`, `identity`, `cubbyhole`, and
  `agent-registry`, which Vault 2.1.1 mounts on its own (N8); and, because a
  tenant's auth mounts start with its name, `token` and the first segment of
  VCO's login mount (`vco.authPath`, default `kubernetes`): Vault refuses an
  auth mount nested under another (N7, Q17);
- in `parent.reservedPaths` (default `secret`, `kv`, `pki`, `transit`,
  `database`, `ssh`, `totp`, `oidc`, `jwt`, `userpass`, `approle`, `ldap`):
  the platform's own secrets and auth mount prefixes, which the parent can't
  read from Vault, so the platform lists them.

A name that collides with a mount the list misses fails in Vault with a 400
on that tenant's mount CR alone, which gets no finalizer (N3, V8); VCO's error
reaches the TemplateInstance outputs — `enginesLastError` on the parent,
`authMountsLastError` on the child (T1; `charts/README.md` → Health) — and no
other tenant is affected.

## 6. VCO's login policy (ADR-0008)

VCO is the only identity that writes Vault configuration, and on Community
Edition it writes in the same namespace as everything else — including its own
policy. Its policy is narrowed **by name and by mount type**. It is the
Enterprise production policy with each tenant namespace `+/` turned into the
tenant prefix (full text and comments:
[`charts/examples/vco-admin-policy.hcl`](../charts/examples/vco-admin-policy.hcl);
the render test `vcopolicy` pins exactly these paths):

```hcl
path "sys/mounts"           { capabilities = ["read"] }
path "sys/mounts/+/kv"      { capabilities = ["create", "read", "update"]          # no delete
                              allowed_parameters = { "type" = ["kv"], "*" = [] } }
path "sys/mounts/+/kv/tune" { capabilities = ["create", "read", "update"] }
path "sys/auth"             { capabilities = ["read"] }
path "sys/auth/+/kubernetes/workloads" { capabilities = ["create", "read", "update", "delete", "sudo"]
                                         allowed_parameters = { "type" = ["kubernetes"], "*" = [] } }
path "sys/auth/+/kubernetes/workloads/tune" { capabilities = ["create", "read", "update", "sudo"] }
path "sys/auth/+/oidc/sso"  { capabilities = ["create", "read", "update", "delete", "sudo"]
                              allowed_parameters = { "type" = ["oidc"], "*" = [] } }
path "sys/auth/+/oidc/sso/tune"                      { capabilities = ["create", "read", "update", "sudo"] }
path "auth/+/kubernetes/workloads/config"            { capabilities = ["create", "read", "update"] }
path "auth/+/kubernetes/workloads/role/kv.*"         { capabilities = ["create", "read", "update", "delete"] }
path "auth/+/kubernetes/workloads/role/share.*"      { capabilities = ["create", "read", "update", "delete"] }
path "auth/+/oidc/sso/config"                        { capabilities = ["create", "read", "update"] }
path "auth/+/oidc/sso/role/sso.*"                    { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/kv.*"    { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/share.*" { capabilities = ["create", "read", "update", "delete"] }
path "sys/policy/sso.*"   { capabilities = ["create", "read", "update", "delete"] }
```

What this gives:

- VCO **can't write its own policy** (`vco-admin`), `default`, or any
  platform policy directly: none starts with `kv.`, `share.` or `sso.`
  (AC-ISO-7).
- VCO **can't edit its own login role**: it lives on `auth/kubernetes`, which
  no path here reaches.
- VCO **can't delete a kv mount**: no `delete` on `sys/mounts/+/kv`. Deleting
  a tenant leaves its data (ADR-0005). It can delete auth mounts, policies and
  roles, which hold grants, not data — as on Enterprise.
- VCO **can't mount any other engine or auth method** in the extension's
  places: `allowed_parameters` pins the type (P5, Q14).
- No VCO call needs `list` or any path outside this policy: in C.0 every kind
  reconciled, was created and was deleted under it (V9, Q17).

What it does **not** give: a bound on what VCO can grant. A `kv.*` policy
can say `path "*"` with `sudo`, and a `kv.*` role can bind it to any
ServiceAccount; with those two CRs, VCO's own permissions produce a token
close to root (P6, Q16). On Enterprise the same two CRs stay inside one
tenant's Vault namespace. So on Community:

- **VCO's token and pod are root-equivalent secrets.** Nobody but VCO may
  create tokens for `vault-config/vco-admin` or exec into VCO; its login role
  binds `vault-config` only (V13).
- **What VCO is asked is bounded at admission** (§4). The `scope` policy
  refuses every CR of Q16's kind, and the `kinds` policy every other kind and
  every `spec.connection`: VCO logs in wherever a CR's connection points, with
  a JWT the `vco-admin` role would accept back. Both hold for any writer of
  `vault-config`.
- **No audience on `vco-admin`.** VCO v1.0.3 requests its token with no
  audience (`api/v1alpha1/utils/commons.go`), so it carries the API server's;
  an audience on the role could only be that one, and would not stop the
  replay of a token VCO sent elsewhere. Refusing `spec.connection` does.

## 7. Lifecycle (ADR-0005)

As in the Enterprise extension, with the mount in the parent's place of the
`Namespace`:

| Event | Extension | Data |
|---|---|---|
| Tenant created | parent renders `<tenant>/kv` | — |
| Tenant gets its first labelled namespace | child TIs render, the tenant's auth mounts included | — |
| ServiceAccount annotated | policy, role, ConfigMap, ESO objects | — |
| Annotation removed, role lowered | policy rewritten or removed, role removed: a token issued before loses the access at once, because Vault reads the policy on every request (the e2e suite asserts it); the token itself lives to its TTL (`token.ttl`, default 1 h) | secrets stay |
| Namespace deleted or relabelled | VCO re-resolves the role's selector within seconds, to `__no_namespace__`; the re-render removes the role (V10) | secrets stay |
| Last namespace unlabelled | child TIs go: every grant revoked, the tenant's auth mounts disabled, every token issued through them revoked (A6) | mount and secrets stay |
| Person leaves a group | nothing | no new SSO login; tokens expire within their TTL |
| Tenant deleted | as above; mount CR stays `Terminating` (VCO's delete refused) | secrets stay until a Vault admin purges them (below) |
| Tenant recreated with the same name | the mount is adopted; peers' `kv-export-tenant`/`kv-import-tenant` naming it apply again | the old secrets come back — purge before reusing a name |

A refused delete is retried: until the admin purges it, a `Terminating` mount
CR adds a 403 to VCO's log and to Vault's audit log on every retry (V9). The
admin purge, in this order:

1. The mount CR is already `Terminating` (the tenant is deleted). Never
   disable a mount whose CR is live: VCO re-creates it, empty, within one
   sync period (V12).
1. `vault secrets disable <tenant>/kv`.
1. Remove the CR's finalizer.
1. Before the name is reused: delete `from-<tenant>/` and `to-<tenant>/` in
   `shared/kv/`, and remove the peers' share annotations that name it.

Shares live in `shared/kv/`, in neither tenant, so deleting a tenant never
deletes one.

## 8. Health and preflight

Inherited from the Enterprise extension: per-kind `<output>Succeeded` and
`<output>LastError` outputs on the TIs (V5, T1; `<output>` is `engines`,
`authMounts`, `k8sAuthRoles`, `policies`, … — `charts/README.md` → Health), ESO sync status on the `.eso`
TI, error ConfigMaps per ServiceAccount, the skipped-tenants ConfigMap. A TI's
own `Ready` does not reflect VCO: the outputs are the signal.

Added for Community Edition:

| Check | How |
|---|---|
| the Vault is Community Edition | install check in `charts/README.md` (the server version has no `+ent`); the e2e preflight asks the server and refuses Enterprise, the mirror of the Enterprise suite refusing Community. The charts call no Vault API themselves |
| the tenant mount exists per tenant | `enginesSucceeded` on the parent's outputs |
| VCO's policy is the narrowed one | install check in `charts/README.md` (a diff with `charts/examples/vco-admin-policy.hcl`); the e2e suite asserts VCO is refused a write to `sys/policy/vco-admin` and a mount of the wrong type |
| the admission policies are in force | the e2e suite runs the 74 live cases of `hack/lab/admission-cases.sh` against the installed policies, and pins that 3 run offline only; `make verify` runs all 77 offline |
| `default` is unchanged | every tenant token carries root's one `default` policy; the install check in `charts/README.md` compares it with a fresh Vault's, and the e2e suite proves VCO can't rewrite it |

## 9. Install requirements

- Vault Community Edition ≥ 2.0; 2.1.1 is the tested baseline.
- **One cluster per Vault.** Each tenant's auth config names this cluster's
  API and CA; a second cluster writing the same
  `auth/<tenant>/kubernetes/workloads/config` would let its workloads pass as
  this cluster's (not run in C.0; Enterprise separates clusters with
  `vco.namespace`).
- VCO ≥ v1.0.3, logging in with the policy in §6, with
  `ENABLE_DRIFT_DETECTION=true` and a short `SYNC_PERIOD_SECONDS` (minutes, not
  VCO's default 10 hours): a policy widened by hand stays wide until the next
  drift reconcile (V7). VCO's login role binds `vco-admin` in `vault-config`
  only (V13); VCO's own RBAC watches namespaces (V10).
- Kubernetes ≥ 1.30, for ValidatingAdmissionPolicy (K2); tested on 1.33.
- Template Operator v2 ≥ 0.0.5 (C.0: `main` at `0b89c9b`). The extension's
  Templates allow only `vault-config` in `targetNamespaces`.
- Only Template Operator and Vault admins create VCO CRs in `vault-config`.
  The admission policies hold for any writer — they refuse what a person, or
  a tenant Template through Template Operator, could write there — but a
  writer can still delete the extension's objects, which revokes access (not
  data). Tenants should not hold create on Templates: their Templates run with
  Template Operator's rights elsewhere too (T2).
- Multi-Tenant Operator labelling tenant namespaces `stakater.com/tenant`;
  only the Multi-Tenant Operator and cluster admins may set that label (the
  trust boundary, unchanged). Namespace names are not reserved per tenant
  (K1): the tenant label in each role's binding covers that.
- External Secrets Operator when `parent.eso=enabled`.
- An OIDC identity provider for SSO, one client shared by every tenant. Each
  tenant's SSO mount has its own UI callback
  (`https://<vault>/ui/vault/auth/<tenant>/oidc/sso/oidc/callback`), so the
  client allows one redirect URI per tenant, or a wildcard; plus
  `http://localhost:8250/oidc/callback` for the CLI, which every mount shares.
  Verified in C.6: the chart takes `{tenant}` in
  `parent.sso.allowedRedirectUris`; Keycloak accepts a wildcard, Dex does not,
  so a Dex client lists every tenant.

## 10. What Community Edition can't isolate (documented, not hidden)

| Shared by every tenant | Consequence | Enterprise or OpenBao |
|---|---|---|
| one root namespace | policy is the only wall; a policy written by hand outside the extension can still cross tenants | a namespace per tenant |
| VCO's Vault identity | close to root: its policy bounds names and mount types, not what a `kv.*` policy grants (P6). Admission bounds what VCO is asked; nothing bounds VCO's token | VCO writes inside tenant namespaces only |
| one auth namespace | a tenant's auth mounts start with its name, so a platform auth mount at that name blocks the tenant (reserved names, §5) | per-namespace auth |
| one audit log (O1) | per-tenant audit is a downstream filter on `<tenant>/` and `auth/<tenant>/` | filtered audit devices (Enterprise) |
| one identity store (N5) | entities and groups are global objects, readable only by Vault admins | per-namespace identity |
| one `default` policy | every tenant token carries it; an edit reaches every tenant (§8) | per-namespace `default` |
| quotas by source address only (O2) | no per-tenant fairness | lease-count quotas (Enterprise) |
| no delegated administration | tenants can never manage policies or mounts — by design here (ADR-0004) | namespace admins |
