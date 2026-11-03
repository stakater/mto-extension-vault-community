# mto-extension-vault-community charts

Two Helm charts that give every Stakater Multi-Tenant Operator (MTO) `Tenant`
its own scope in one shared **Vault Community Edition**, configured through
[vault-config-operator](https://github.com/redhat-cop/vault-config-operator)
(VCO) custom resources. They are a port of the Enterprise extension's charts
(`stakater/mto-extension-vault-enterprise`), with the same annotations, roles,
object names and ConfigMap keys.

| Chart | Installed | Role |
|---|---|---|
| [mto-extension-vault-community-bootstrap](mto-extension-vault-community-bootstrap/) | once per cluster, by hand | Watches `Tenant` CRs and fans out one render per tenant. Renders every tenant's KV mount and the shared mounts. Creates the ServiceAccount VCO logs in with. |
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
| shared namespace `auth/kubernetes/workloads/` | `auth/shared/kubernetes/workloads/` |

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
                                      AuthEngineMount shared-kubernetes    → auth/shared/kubernetes/workloads
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
