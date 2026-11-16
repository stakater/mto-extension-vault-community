# mto-extension-vault-community charts

Two Helm charts that give every Stakater Multi-Tenant Operator (MTO) `Tenant`
its own scope in one shared **Vault Community Edition**, configured through
[vault-config-operator](https://github.com/redhat-cop/vault-config-operator)
(VCO) custom resources. They are a port of the Enterprise extension's charts
(`stakater/mto-extension-vault-enterprise`), with the same annotations, roles,
object names and ConfigMap keys.

| Chart | Installed | Role |
|---|---|---|
| [mto-extension-vault-community-bootstrap](mto-extension-vault-community-bootstrap/) | once per cluster, by hand | Watches `Tenant` CRs and fans out one render per tenant. Renders every tenant's KV mount and the shared mount. Creates the ServiceAccount VCO logs in with. |
| [mto-extension-vault-community](mto-extension-vault-community/) | never by hand | Per-tenant template. template-operator-v2 (t-op-v2) pulls it and renders it once per `Tenant`. |

The charts only *describe* configuration: they emit VCO CRs, and VCO writes them
to Vault. Transit, PKI and cert-manager integration are **not** supported yet.

## A tenant is a path prefix

Vault Community Edition has no namespaces. Every tenant gets the Enterprise
paths with its name in front, in Vault's one namespace:

| Enterprise (in namespace `<tenant>`) | Community (in root) |
|---|---|
| `kv/` | `<tenant>/kv/` |
| `auth/kubernetes/workloads/` | `auth/<tenant>/kubernetes/workloads/` |
| `auth/oidc/sso/` | `auth/<tenant>/oidc/sso/` |
| shared namespace `kv/` | `shared/kv/` |
| shared namespace `auth/kubernetes/workloads/` | none: share roles live on `auth/<tenant>/kubernetes/workloads/` |

The policy is the only wall between tenants. Every policy and role the charts
render passes a scope check (`docs/design.md` §4), and the bootstrap chart's
admission policies apply the same check to every VCO CR, whoever writes it.

## Prerequisites

- **Vault Community Edition** 2.x (tested on 2.1.1).
- **vault-config-operator v1.0.3 or later**, with drift detection on and a
  short sync period.
- template-operator-v2 ≥ 0.0.5 (child TemplateInstances need
  `namespaceSelector`).
- Kubernetes 1.30 or later (ValidatingAdmissionPolicy).
- MTO's `Tenant` CRD. MTO labels each tenant namespace with
  `stakater.com/tenant: <tenant>`; that label is what the charts key on.
- External Secrets Operator, only if `parent.eso=enabled` (the default).
- One cluster per Vault: each tenant's auth config names this cluster's API.

## How it fits together

```text
Tenant CRs ──► parent TemplateInstance (mto-extension-vault-community-parent)
                 once per cluster     SecretEngineMount shared-kv          → shared/kv
                 per Tenant           SecretEngineMount <tenant>-kv        → <tenant>/kv
                 per Tenant with a    TemplateInstance mto-extension-vault-community-<tenant>      → core slice
                 labelled namespace   TemplateInstance mto-extension-vault-community-<tenant>.eso  → eso slice
```

**A tenant's kv mount lives as long as its `Tenant` CR**, not as long as its
namespaces. The parent renders it for every valid Tenant. The workload render
exists only while the tenant has at least one labelled namespace: its child
TemplateInstance would otherwise fail parameter validation. So deleting a
tenant's last namespace removes its grants and keeps its secrets; labelling a
namespace again brings the grants back.

### Tenant names

The parent **skips** a Tenant, and lists it with the reason in the ConfigMap
`mto-extension-vault-community-skipped-tenants` in `configNamespace`, when its
name is:

- not a DNS label, or longer than 29 characters: the child TemplateInstance
  `mto-extension-vault-community-<tenant>.eso` is a label value on every object
  it renders, and a label value caps at 63. (Set before the first release:
  lowering it later would skip tenants that rendered before.)
- the shared name (`parent.sharedTenantName`, default `shared`);
- the first segment of a path Vault or the platform already uses. A tenant's
  mounts start with its name, and Vault refuses a mount nested under another.
  Always reserved: `sys`, `auth`, `identity`, `cubbyhole`, `agent-registry`,
  `token`, and the first segment of `vco.authPath` (VCO's own login mount,
  default `kubernetes`). Also reserved: every entry of `parent.reservedPaths`,
  which lists the platform's own secrets and auth mount prefixes (default
  `secret`, `kv`, `pki`, `transit`, `database`, `ssh`, `totp`, `oidc`, `jwt`,
  `userpass`, `approle`, `ldap`). The parent can't read Vault's mount tables,
  so add any other mount your platform has.

## Vault bootstrap (one time, by a Vault admin)

VCO logs in to Vault with the Kubernetes auth method as the ServiceAccount the
bootstrap chart creates. Before the bootstrap chart can do anything, a Vault
admin sets up that login:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443
vault policy write vco-admin examples/vco-admin-policy.hcl
vault write auth/kubernetes/role/vco-admin \
  bound_service_account_names=vco-admin \
  bound_service_account_namespaces=vault-config \
  token_policies=vco-admin token_ttl=1h
```

`kubernetes_host` without `token_reviewer_jwt`: Vault then reviews tokens with
its own ServiceAccount, which must be bound to `system:auth-delegator` (the
HashiCorp Helm chart does this by default). No reviewer credential is stored.

The first segment of VCO's login mount (`kubernetes` here) becomes a reserved
tenant name: Vault refuses an auth mount nested under another, and every
tenant's auth mounts start with the tenant's name.

[examples/vco-admin-policy.hcl](examples/vco-admin-policy.hcl) is the
production policy. It is narrowed **by name and by mount type**: policies only
in the `kv.`, `share.` and `sso.` families, roles only on the extension's
mounts and never on VCO's own `auth/kubernetes`, kv mounts without `delete`
(deleting a tenant keeps its data, ADR-0005), and every mount's type pinned. The lab uses the
same policy plus `delete` on the kv mounts, so its e2e teardown can finish.

**Other mount paths.** The policy names the default mounts: the workload mount
`+/kubernetes/workloads` and the SSO mount `+/oidc/sso`. With other values,
VCO gets `deny` on every tenant's auth mounts until you change the policy:
replace every `kubernetes/workloads` with
`<kubernetesAuth.path>/<kubernetesAuth.name>`, and every `oidc/sso` with
`<tenantValues.sso.mount.path>/<tenantValues.sso.mount.name>`, each without the
slashes around it. For example, `kubernetesAuth: {path: k8s, name: apps}` gives
`sys/auth/+/k8s/apps` and `auth/+/k8s/apps/role/kv.*`. Change nothing else.
`make admission-offline` checks that the policy covers every Vault path VCO
writes for the charts' render, for the default values and, with this rule,
for other ones.

**VCO's token is root-equivalent all the same.** Vault Community has no
namespace to contain what a `kv.*` policy grants, so VCO's own policy bounds
names, not content. Nobody but VCO may create tokens for
`vault-config/vco-admin` or exec into VCO's pod; its login role binds
`vault-config` only. What VCO is asked is bounded by the admission policies
below.

## Admission policies

The bootstrap chart installs four ValidatingAdmissionPolicies on the
`redhatcop.redhat.io` objects in `configNamespace` (Kubernetes 1.30 or later).
They are the wall between tenants that Vault Community does not have, and they
hold for every writer of `configNamespace` — the charts, Template Operator, a
person:

| Policy | Refuses |
|---|---|
| `mto-extension-vault-community-vco-kinds` | a VCO CR without a spec; any kind but the seven the extension renders (VCO has about 80: an `AppRoleAuthEngineRole` would write a role on a tenant's mount unchecked); any `spec.connection` (VCO would send its root-equivalent login JWT to that address); any `spec.authentication` but the install's `vco.authPath`, `vco.role` and `vco.serviceAccount`, or one with a Vault namespace. |
| `mto-extension-vault-community-vco-origin` | an object Template Operator renders for a TemplateInstance outside `configNamespace`. A Template in a tenant namespace can name `configNamespace`, and Template Operator applies it with its own rights. Template Operator stamps every object it writes with its source (`templates.v2.stakater.com/instance-namespace`), so this holds for any writer, even with a wrong `templateOperator.*`. |
| `mto-extension-vault-community-vco-scope` | a policy, role or mount outside its tenant's scope: a name outside the `kv.`, `share.` and `sso.` families, a policy with a `type`, a policy line that is not a one-line `path` stanza or grants `sudo`, a path outside `<tenant>/kv/…` (or its share in `shared/kv/…`), a role not bound to exactly its own policy, its tenant's mount, its ServiceAccount and its namespace by name and tenant label, an SSO role not bound to exactly its tenant's group, a mount of another shape or at a reserved name, an OIDC config at another issuer. |
| `mto-extension-vault-community-vco-cluster` | a Kubernetes auth config for another API or another CA than this cluster's `kube-root-ca.crt`. |

Each has failure policy `Fail`. A deletion is not refused: VCO's finalizer
updates pass while the spec is unchanged, or while neither side has a spec (a
CR written with the policies off); a spec changed, removed or added during a
deletion is checked. The one exception: while `configNamespace` has no
`kube-root-ca.crt` (kube-controller-manager makes it in every namespace), the
cluster policy refuses every write of a Kubernetes auth config, a finalizer
update too. `admission.enabled` exists only for clusters older than 1.30;
turning it off removes the wall. A null or commented-out `admission.enabled`
is the default, on, but not on `helm upgrade --reuse-values` (see *Null and
`--reuse-values`* below). `make admission-offline` runs the policies' CEL against
the 109 cases of `hack/lab/admission-cases.sh` without a cluster, and against
every VCO CR the charts render for two install value sets (it is part of
`make verify`); a refusal counts only with its rule's message. `make
admission-test` runs 104 of the cases on the lab, the update and deletion
cases on an old object it creates and holds in deletion. The 5 that can't be
made live run offline only.

**Who writes to `configNamespace`.** Only Template Operator and Vault admins
should. The policies hold for anyone who can, but a writer there can still
delete the extension's objects, which revokes tenants' access (never their
data: VCO can't delete a kv mount).

## Install

```bash
helm upgrade --install mto-extension-vault-community-bootstrap \
  oci://ghcr.io/stakater/charts/mto-extension-vault-community-bootstrap \
  -n vault-config --create-namespace \
  --set parent.vaultServer=https://vault.example.com:8200
```

Values that matter (bootstrap chart):

| Value | Default | Meaning |
|---|---|---|
| `configNamespace` | `vault-config` | Holds every Template, TemplateInstance and VCO CR. Install the chart into it. |
| `vco.authPath` / `vco.role` / `vco.serviceAccount` | `kubernetes` / `vco-admin` / `vco-admin` | How VCO logs in. Must match the Vault bootstrap. There is no `vco.namespace`. |
| `kubernetesAuth.path` / `.name` | `kubernetes` / `workloads` | The workload auth mount: `auth/<tenant>/kubernetes/workloads`. Not the SSO mount's path (`tenantValues.sso.mount`, `oidc/sso`), and not inside it or around it: the install fails. VCO's policy names both mounts: change it with them (*Other mount paths* above). |
| `kubernetesAuth.tokenReviewerServiceAccount` | `""` | Set only when Vault runs outside the cluster. A ServiceAccount name; a malformed one fails the install. |
| `templateOperator.serviceAccountName` / `.namespace` | `template-operator-template-operator-v2` / `stakater-template-operator` | t-op-v2's identity, which the RBAC binds to. A name each; an empty or malformed value fails the install. |
| `tenantChart.registry` / `.version` | `oci://ghcr.io/stakater/charts` / chart version | Where t-op-v2 pulls the tenant chart. |
| `parent.sharedTenantName` | `shared` | The prefix of the shared mount `shared/kv`. A DNS label that is not itself reserved (`sys`, a `parent.reservedPaths` entry, …); it becomes a reserved tenant name. |
| `parent.reservedPaths` | see above | The platform's own mount prefixes. Reserved tenant names. |
| `parent.eso` | `enabled` | `"enabled"` or `"disabled"` — a string, not a boolean. Null is the default, but not on `helm upgrade --reuse-values` (see below). |
| `parent.token` | `{}` | Workload token `type`, `ttl`, `maxTTL`. **Integer seconds.** `0` means Vault's default. A side not set is the tenant chart's default (`ttl` 3600, `maxTTL` 14400), and a `ttl` over the `maxTTL` fails the install. |
| `parent.sso.*` | off | Human SSO. `enabled=true` requires `issuerUrl`; the install fails without it. |
| `tenantValues` | `{}` | Any other tenant chart value, install-wide: `vaultCABundle`, `monitoring`, `sso.oidc.*`, `sso.roles`, `roleCaps`, `ssoToken`, … A key this chart already sets fails the render and names the value to use. |

**Null and `--reuse-values`.** A null value, or a key commented out, takes the
chart default (`admission.enabled` on, `parent.eso` enabled). That holds for a
values file and for `--set`, but not on `helm upgrade --reuse-values`: Helm
then computes the value from the release's old one, and the chart never gets
the null. With Helm 3.14.0, after `--set parent.eso=disabled`,
`helm upgrade --reuse-values --set parent.eso=null` stores `eso: null` and
leaves ESO off (`helm get values --all` shows `disabled`). To go back to a
default, set the value itself (`--set parent.eso=enabled`,
`--set admission.enabled=true`), or upgrade with all your values again and
without `--reuse-values`.

t-op-v2 pulls the **published** tenant chart, so `tenantValues` is the only way
to set a tenant chart value on a cluster; editing the tenant chart's own
`values.yaml` changes nothing.

The schema refuses a key the charts do not read — at the top level, in
`vco`, `parent`, `parent.sso`, `parent.token`, `templateOperator`,
`kubernetesAuth`, `tenantChart`, `sync`, `admission`, and in `tenantValues`,
`tenantValues.sso`, `.sso.oidc`, `.sso.oidc.clientSecretRef`, `.sso.mount`,
`.ssoToken` and `.monitoring` — so a misspelt key fails the install instead of
being ignored. It also gives each `tenantValues` value the type the tenant
chart reads (`roleCaps` a map of strings, `ssoToken` duration strings,
`clientSecretRef` a name and a key, …), so a wrong type fails the install, not
every tenant's render later. An `ssoToken.ttl` over its `maxTTL` fails the
install too (a side not set is the tenant chart's default, 15m and 1h): Vault
refuses such an SSO role. So does an empty `sso.roles` with SSO on, and a null
`kubernetesAuth.kubernetesHost` or `tenantChart.version`.

### Install checks

Run once after the install, and after any change to Vault outside the
extension. The charts call no Vault API themselves, so these are the
platform's to run:

```bash
# Vault is Community Edition: the server's version has no +ent suffix (the e2e preflight's check).
vault status -format=json | jq -r .version
# VCO's policy is the production one, unchanged.
diff <(vault policy read vco-admin) charts/examples/vco-admin-policy.hcl
# default is Vault's built-in policy: every tenant token carries it, so an edit reaches every tenant.
vault policy read default
```

Compare the last one with the `default` policy of a fresh Vault of the same
version (`vault server -dev`). The e2e suite proves the rest on the lab: its
preflight refuses an Enterprise server, VCO is refused writing `vco-admin` and
`default`, and the admission cases run.

## Trust boundary

**The `stakater.com/tenant` label on a namespace is what grants a tenant's
Vault access.** The parent finds a tenant's namespaces by that label, and the
tenant chart renders a Policy and Role for every annotated ServiceAccount in
them. So anyone who can set `stakater.com/tenant: X` on a namespace can give
their own ServiceAccounts tenant X's Vault access.

Keep that label under the platform's control: only MTO (and cluster admins)
may set or change it. Tenant users must not be able to label or relabel
namespaces — in particular they must not hold `patch` or `update` on
`namespaces` at cluster scope. MTO's own namespace handling is built on the same
label, so this is the same rule MTO already needs.

Each role binds its namespace by **name and tenant label**, so a namespace name
that another tenant creates later, after the first one is deleted, gets nothing:
Kubernetes does not reserve namespace names per tenant.

Inside a tenant, the ServiceAccount annotations decide which app gets which
access. Anyone who can annotate a ServiceAccount in a tenant namespace can
request that tenant's access for it, up to the `admin` role.

## Workload access

Access is opt-in per ServiceAccount, with annotations:

| Annotation | Value | Effect |
|---|---|---|
| `vault.stakater.com/kv` | `"true"` | The app's own KV prefix. |
| `vault.stakater.com/role` | `viewer` \| `editor` \| `admin` \| `audit-read` | Required with `kv`. How much access. |
| `vault.stakater.com/app` | name | The app that owns the prefix. Default: the ServiceAccount name. |
| `vault.stakater.com/kv-subscribe-ns` | CSV of namespaces | Read-only access to those sibling namespaces' `_shared/` prefix, in the same tenant. |
| `vault.stakater.com/kv-export-tenant` | CSV of tenants | Write access to `shared/kv/…/from-<own>/to-<peer>/`. |
| `vault.stakater.com/kv-import-tenant` | CSV of tenants | Read access to `shared/kv/…/from-<peer>/to-<own>/`. |

The KV layout inside the tenant's `<tenant>/kv` mount:

```text
<tenant>/kv/data/<env>/<namespace>/<app>/...           the app's own secrets
<tenant>/kv/data/<env>/_shared/from-<namespace>/...    written by that namespace's editor/admin apps,
                                                       read by every app there and by subscribers
```

A subscription is read-only on the producer's prefix, on the data path and on
the metadata path: KV v2 metadata `update` sets `max_versions`, which destroys
versions. A namespace outside the tenant can't be subscribed to.

Shares between tenants live in the shared mount, in neither tenant's:

```text
shared/kv/data/<env>/from-<tenant>/to-<peer>/...   written by <tenant>'s exporting apps,
                                                   read by <peer>'s importing apps
```

The share roles `share.<tenant>.<namespace>.<sa>.out.<peer>` and `….in.<peer>`
live on the tenant's own auth mount, so a share login uses `VAULT_K8S_MOUNT`
like any other (ADR-0007), and offboarding the tenant revokes its share tokens
too. A share to a tenant that does not exist yet renders nothing, and appears
when that tenant does.

For each annotated ServiceAccount the chart renders a `Policy` and a
`KubernetesAuthEngineRole` named `kv.<tenant>.<namespace>.<sa>`, on the
tenant's mount `auth/<tenant>/kubernetes/workloads`, and a ConfigMap
`vault-config-<sa>` in the workload namespace:

```text
VAULT_ADDR, VAULT_CACERT (with vaultCABundle), VAULT_NAMESPACE="" (Community has none),
VAULT_K8S_MOUNT=<tenant>/kubernetes/workloads, VAULT_K8S_ROLE,
VAULT_KV_APP, VAULT_KV_APP_PATH=<tenant>/kv/data/<env>/<namespace>/<app>/, VAULT_KV_APP_META_PATH,
VAULT_KV_SHARED_OUT_PATH, VAULT_FROM_<NS>_PATH (per subscription),
VAULT_OUT_<PEER>_NAMESPACE="" / _ROLE / _PATH, VAULT_IN_<PEER>_NAMESPACE="" / _ROLE / _PATH
```

The keys are the Enterprise extension's. `VAULT_NAMESPACE` is present and
empty, and every path starts with the tenant, so a client written for
Enterprise works unchanged.

Every policy passes the **scope check** before it is rendered: one-line
`path "…" { capabilities = [...] }` stanzas, no `sudo`, no `+`, and every path
inside `<tenant>/kv/{data,metadata,delete,undelete,destroy}/<env>/`. A policy
that fails it fails the render. A `roleCaps` entry with `sudo` fails too.

A misconfigured ServiceAccount gets a ConfigMap `vault-config-<sa>.error` that
says what is wrong, and nothing else. Reported per ServiceAccount rather than
failing the render, so one namespace's mistake does not stop the tenant's other
namespaces. An unknown `vault.stakater.com/` key is an error, not ignored; so
are `transit` and `pki`, which this extension does not support.

### ExternalSecrets

With ESO enabled (`parent.eso=enabled`), every annotated ServiceAccount also
gets a `SecretStore <sa>-vault`. It logs in as the ServiceAccount at
`<tenant>/kubernetes/workloads`, reads the tenant's mount `<tenant>/kv` (KV v2),
and has no Vault namespace. Annotate the Deployment:

| Annotation | Value | Reads |
|---|---|---|
| `vault.stakater.com/kv-secret.<name>` | `<leaf>[#<key>]` | the app's own `<leaf>`; with `#<key>` only that key, else every key of the leaf |
| `vault.stakater.com/kv-subscribe.<name>` | `<writer-ns>/<leaf>[#<key>]` | a `_shared/` leaf of the own namespace, or of a subscribed one |
| `vault.stakater.com/kv-import.<name>` | `<peer>/<leaf>[#<key>]` | an imported share leaf, through SecretStore `<sa>.share-<peer>-vault` on `shared/kv` |

Each renders ExternalSecret and Secret `<sa>-<name>`, where `<sa>` is the
Deployment's `serviceAccountName`. It must be an annotated ServiceAccount that
grants the path; otherwise a `vault-config-<deployment>.deploy-error`
ConfigMap explains why. Two Deployments that ask for the same secret through
one ServiceAccount share one ExternalSecret; two that ask for different
secrets under one name are both refused. With ESO disabled install-wide, a
Deployment that asks gets a `deploy-error` and no Secret.

ESO re-reads Vault every `parent.externalSecretRefreshInterval` (default 1h)
and updates the Secret. An environment variable is read only at container
start, so to roll the Deployment when the Secret changes, add Stakater
Reloader's own annotation to it — the charts render nothing for it:

```yaml
metadata:
  annotations:
    vault.stakater.com/kv-secret.db: "db#password"
    secret.reloader.stakater.com/reload: "<sa>-db"
```

## Human SSO

With `parent.sso.enabled=true`, each tenant gets its own OIDC auth mount
`auth/<tenant>/oidc/sso` and one Vault role per entry of `sso.roles`, named
`sso.<tenant>.<role>`, bound to exactly the IdP group `<tenant>-<role>s`
(`sso.tenantGroupTemplate`). Each role's policy reaches the tenant's mount
`<tenant>/kv` at that role's capabilities, and nothing else: no role, `admin`
included, can write a policy, a mount, an auth role or the mount's config.

Every tenant uses one IdP client, `sso.oidc.clientId` (also the audience every
role accepts, because an ID token's `aud` is the client ID). Its secret is a
Secret in `configNamespace`, `sso.oidc.clientSecretRef`.

**Redirect URIs are per tenant.** Vault Community has no namespaces, so each
tenant's mount has its own UI callback:
`https://<vault>/ui/vault/auth/<tenant>/oidc/sso/oidc/callback`. Write it once
in `parent.sso.allowedRedirectUris` with `{tenant}`, and each tenant's roles get
their own:

```yaml
parent:
  sso:
    enabled: true
    issuerUrl: https://idp.example.com
    allowedRedirectUris:
      - http://localhost:8250/oidc/callback            # the vault CLI, same for every mount
      - https://vault.example.com/ui/vault/auth/{tenant}/oidc/sso/oidc/callback
```

The IdP client must allow the same URIs: one per tenant, or a wildcard where
the IdP supports one. Keycloak accepts `…/ui/vault/auth/*`; Dex has no
wildcard, so its client lists every tenant (the lab's `make lab-dex` builds
that list). Enterprise avoids this with `namespace_in_state`.

```bash
vault login -method=oidc -path=<tenant>/oidc/sso role=sso.<tenant>.editor
```

A role works only for its group, and only in its tenant: a login with another
group's role is refused with "does not match any associated bound claim
values". The install fails when a group pattern (`sso.tenantGroupTemplate`, or
a role's `sso.tenantRoleMapping.<role>.pattern`) does not hold `{tenant}`
exactly once — one group would get that role in every tenant; give
platform-wide access with a Vault admin policy instead — or when two roles'
patterns can give the same group to two tenants, or to one tenant's two roles
(`{tenant}` alone would give one group all four roles). It also fails on an
SSO value that would fail every tenant's render later: a role without a
`roleCaps` entry, listed twice or named `fallback`; a `roleCaps` value that is
not one capability list, or holds `sudo`; a `tenantRoleMapping` entry other
than `{}` or `{pattern: …}`; `fallback` other than `deny`; an empty
`tenantGroupTemplate` or SSO mount path; a pattern with a quote, a double
quote, a backslash or a control character such as a newline (the admission
policies embed every pattern, and their YAML turns a newline into a space). With the default
`{tenant}-{role}s`, roles `audit-read` and `read` would: tenant `x` as
`audit-read` and tenant `x-audit` as `read` both bind `x-audit-reads`. Put a
character a tenant name can't hold between `{tenant}` and the rest
(`{tenant}.{role}`), or rename the role. There is no fallback role: `sso.tenantRoleMapping.fallback` must stay
`deny`, because a role without a group binding would give any valid token of
the IdP that tenant's access. A person removed from a group can't log in
again; a token already issued lives to its TTL (`ssoToken.ttl`, default 15m).

## Monitoring

`tenantValues.monitoring.enabled=true` renders one PrometheusRule per tenant,
`mto-extension-vault-community-<tenant>` in `monitoring.prometheusNamespace`,
with one alert: `VaultExternalSecretSyncFailed`, an ExternalSecret in one of
the tenant's namespaces not Ready for 5 minutes. It needs the
prometheus-operator CRDs and ESO's metrics scraped.

## Health

VCO's status can't say whether an object is healthy now: its
`ReconcileSuccessful` and `ReconcileFailed` conditions freeze after their
first write. So the TemplateInstance outputs say two things per object:

| Output field | Means |
|---|---|
| `<output>Succeeded` | `["True"]` once the object was written to Vault at least once; `[]` means never — the one clear failure |
| `<output>LastError` | the message of the most recent failed reconcile, ever; it stays after the object recovers |

The parent TI reports each tenant's kv mount (`engines…`); each tenant's child
TI reports its auth mounts, configs, roles and policies (`authMounts…`,
`k8sAuthRoles…`, `policies…`, `oidcRoles…`). A TI's own `Ready` does not
reflect VCO: read the outputs.

```bash
kubectl -n vault-config get templateinstances.templates.v2.stakater.com mto-extension-vault-community-parent \
  -o jsonpath='{.status.outputs.enginesLastError}'
```

A tenant named like a platform mount the reserved list misses shows here: its
kv mount fails on the parent's `enginesLastError` ("path is already in use"),
its auth mount on its child's `authMountsLastError`, and no other tenant is
affected. Add the name to `parent.reservedPaths`, and rename or delete the
tenant.

## Deletion

Access ends at once; data stays until a Vault admin purges it.

| Event | What goes | What stays |
|---|---|---|
| Annotation removed | the policy, role and ConfigMap; a token issued before loses access at once (Vault reads a token's policies by name) | the app's secrets |
| Role lowered | the policy is rewritten in place; an issued token follows at once | secrets |
| Tenant's last labelled namespace deleted | its child TemplateInstances: every grant, **its auth mounts — which revokes every token issued through them**, share tokens included | `<tenant>/kv` and its secrets |
| Tenant deleted | as above; the `<tenant>-kv` CR stays `Terminating`, because VCO's production policy may not disable a kv mount | the mount, its secrets, and the shares in `shared/kv` |
| Tenant recreated with the same name | — | the retained secrets come back: **purge before reusing a name** |

A refused delete is retried: until the admin purges it, a `Terminating` mount
CR adds a 403 to VCO's log and to Vault's audit log on every retry.

The purge, by a Vault admin, in this order:

1. Check that the mount CR is already `Terminating` (the tenant is deleted).
   **Never disable a mount whose CR is live**: VCO re-creates it, empty,
   within one sync period.
1. `vault secrets disable <tenant>/kv`.
1. Remove the CR's finalizer:
   `kubectl -n vault-config patch secretenginemounts.redhatcop.redhat.io <tenant>-kv --type merge -p '{"metadata":{"finalizers":null}}'`.
1. Before the name is reused: delete `from-<tenant>/` and `to-<tenant>/` in
   `shared/kv/`, and remove the peers' `kv-export-tenant` and
   `kv-import-tenant` entries that name it.

## Uninstall

In this order, so the RBAC and VCO's login ServiceAccount outlive every CR
they tear down:

```bash
kubectl -n vault-config delete templateinstances.templates.v2.stakater.com mto-extension-vault-community-parent --wait
# wait until no VCO CR is left in vault-config (the kv mount CRs stay Terminating
# under the production policy: purge them first, as above)
helm uninstall mto-extension-vault-community-bootstrap -n vault-config
```

A bare `helm uninstall` deletes the RBAC and the VCO login ServiceAccount
first, and every CR then waits `Terminating` for a login that no longer
exists. `make lab-uninstall` runs this order.
