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

- not a DNS label, or longer than 63 characters (it is a label value);
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

**VCO's token is root-equivalent all the same.** Vault Community has no
namespace to contain what a `kv.*` policy grants, so VCO's own policy bounds
names, not content. Nobody but VCO may create tokens for
`vault-config/vco-admin` or exec into VCO's pod; its login role binds
`vault-config` only. What VCO is asked is bounded by the admission policies
below.

## Admission policies

The bootstrap chart installs three ValidatingAdmissionPolicies on the VCO CRs
in `configNamespace` (Kubernetes 1.30 or later). They are the wall between
tenants that Vault Community does not have, and they hold for every writer of
`configNamespace` — the charts, Template Operator, a person:

| Policy | Refuses |
|---|---|
| `mto-extension-vault-community-vco-origin` | a VCO CR that Template Operator writes for a TemplateInstance outside `configNamespace`. A Template in a tenant namespace can name `configNamespace`, and Template Operator applies it with its own rights. |
| `mto-extension-vault-community-vco-scope` | a policy, role or mount outside its tenant's scope: a name outside the `kv.`, `share.` and `sso.` families, a policy line that is not a one-line `path` stanza or grants `sudo`, a path outside `<tenant>/kv/…` (or its share in `shared/kv/…`), a role not bound to exactly its own policy, its tenant's mount, its ServiceAccount and its namespace by name and tenant label, an SSO role not bound to exactly its tenant's group, a mount of another shape or at a reserved name, an OIDC config at another issuer. |
| `mto-extension-vault-community-vco-cluster` | a Kubernetes auth config for another API or another CA than this cluster's `kube-root-ca.crt`. |

Each has failure policy `Fail`. A deletion is never refused. `admission.enabled`
exists only for clusters older than 1.30; turning it off removes the wall.

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
| `kubernetesAuth.path` / `.name` | `kubernetes` / `workloads` | The workload auth mount: `auth/<tenant>/kubernetes/workloads`. |
| `kubernetesAuth.tokenReviewerServiceAccount` | `""` | Set only when Vault runs outside the cluster. |
| `templateOperator.serviceAccountName` / `.namespace` | `template-operator-template-operator-v2` / `stakater-template-operator` | t-op-v2's identity, which the RBAC binds to. |
| `tenantChart.registry` / `.version` | `oci://ghcr.io/stakater/charts` / chart version | Where t-op-v2 pulls the tenant chart. |
| `parent.sharedTenantName` | `shared` | The prefix of the shared mounts. A reserved tenant name. |
| `parent.reservedPaths` | see above | The platform's own mount prefixes. Reserved tenant names. |
| `parent.eso` | `enabled` | `"enabled"` or `"disabled"` — a string, not a boolean. |
| `parent.token` | `{}` | Workload token `type`, `ttl`, `maxTTL`. **Integer seconds.** |
| `parent.sso.*` | off | Human SSO. `enabled=true` requires `issuerUrl`; the install fails without it. |
| `tenantValues` | `{}` | Any other tenant chart value, install-wide: `vaultCABundle`, `monitoring`, `sso.oidc.*`, `sso.roles`, `roleCaps`, `ssoToken`, … A key this chart already sets fails the render and names the value to use. |

t-op-v2 pulls the **published** tenant chart, so `tenantValues` is the only way
to set a tenant chart value on a cluster; editing the tenant chart's own
`values.yaml` changes nothing.

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

The KV layout inside the tenant's `<tenant>/kv` mount:

```text
<tenant>/kv/data/<env>/<namespace>/<app>/...           the app's own secrets
<tenant>/kv/data/<env>/_shared/from-<namespace>/...    written by that namespace's editor/admin apps,
                                                       read by every app there and by subscribers
```

A subscription is read-only on the producer's prefix, on the data path and on
the metadata path: KV v2 metadata `update` sets `max_versions`, which destroys
versions. A namespace outside the tenant can't be subscribed to.

For each annotated ServiceAccount the chart renders a `Policy` and a
`KubernetesAuthEngineRole` named `kv.<tenant>.<namespace>.<sa>`, on the
tenant's mount `auth/<tenant>/kubernetes/workloads`, and a ConfigMap
`vault-config-<sa>` in the workload namespace:

```text
VAULT_ADDR, VAULT_CACERT (with vaultCABundle), VAULT_NAMESPACE="" (Community has none),
VAULT_K8S_MOUNT=<tenant>/kubernetes/workloads, VAULT_K8S_ROLE,
VAULT_KV_APP, VAULT_KV_APP_PATH=<tenant>/kv/data/<env>/<namespace>/<app>/, VAULT_KV_APP_META_PATH,
VAULT_KV_SHARED_OUT_PATH, VAULT_FROM_<NS>_PATH (per subscription)
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

Each renders ExternalSecret and Secret `<sa>-<name>`, where `<sa>` is the
Deployment's `serviceAccountName`. It must be an annotated ServiceAccount that
grants the path; otherwise a `vault-config-<deployment>.deploy-error`
ConfigMap explains why. Two Deployments that ask for the same secret through
one ServiceAccount share one ExternalSecret; two that ask for different
secrets under one name are both refused. With ESO disabled install-wide, a
Deployment that asks gets a `deploy-error` and no Secret.

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
values". There is no fallback role: `sso.tenantRoleMapping.fallback` must stay
`deny`, because a role without a group binding would give any valid token of
the IdP that tenant's access. A person removed from a group can't log in
again; a token already issued lives to its TTL (`ssoToken.ttl`, default 15m).
