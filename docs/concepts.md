# Concepts

A plain-language primer. One running example throughout: tenant **`team-a`**,
namespaces **`team-a-api`** and **`team-a-worker`**, application **`web`**
(ServiceAccount `web` in `team-a-api`), environment **`dev`**.

## The terms

| Term | Where it lives | What it is |
|---|---|---|
| **Tenant** | Multi-Tenant Operator | The unit of ownership: a team and its namespaces. Every tenant namespace carries the label `stakater.com/tenant=<tenant>`. |
| **Secret scope** | the product abstraction | Everything a tenant may reach in Vault. On Enterprise it is a Vault namespace; here it is a mount path, policies and login roles. |
| **Tenant mount** | Vault, root | The tenant's own KV v2 engine at `<tenant>/kv/` — `team-a/kv/`. Rendered for every `Tenant`; lives as long as the `Tenant`. |
| **Shared mount** | Vault, root | One KV v2 engine at `shared/kv/` for cross-tenant exchange, `from-<writer>/to-<reader>/`. Created once by the bootstrap chart. |
| **Policy** | Vault, root | A Vault ACL policy. Names carry the tenant, joined with dots: `kv.team-a.team-a-api.web`, `sso.team-a.editor`, `share.team-a.team-a-api.web.out.team-b`. |
| **Tenant auth mounts** | Vault, root | The tenant's own Kubernetes auth mount at `auth/<tenant>/kubernetes/workloads/` and, with SSO, OIDC mount at `auth/<tenant>/oidc/sso/` — the Enterprise paths with the tenant in front. Rendered by the per-tenant chart; disabling them revokes the tenant's tokens. |
| **Login role** | Vault, on the tenant's auth mounts, share roles included | A Kubernetes auth role per annotated ServiceAccount, bound to its namespace's name and tenant label, or an OIDC role per access role. Same name as its policy. |
| **Scope check** | render tests and admission | The rule that every path in every policy rendered for a tenant stays inside that tenant's mount or its named shares, and every role binds only its own policy, mount and namespace. Checked at render and, by admission policies, on every VCO CR in `vault-config`. The Community Edition substitute for a namespace wall. |
| **Access role** | annotation or identity-provider group | `audit-read`, `viewer`, `editor`, `admin`. Workloads get it from `vault.stakater.com/role`; people from the group `<tenant>-<role>s`. Enterprise names it a role, as here; it is not a login role. |
| **VCO** | the cluster | vault-config-operator: turns `Policy`, `SecretEngineMount`, auth role CRs into Vault configuration. Logs in with its own role. |
| **Template Operator** | Stakater | Renders the per-tenant chart once per tenant. |
| **Bootstrap chart** | this repo | Installed once per cluster. Watches tenants, renders each tenant's mount, the shared mount, and the admission policies on VCO CRs. |
| **Per-tenant chart** | this repo | Pulled and rendered by Template Operator per tenant: the tenant's auth mounts, policies, roles, ConfigMaps, ESO objects. Never installed by hand. |

Two words that are easy to confuse:

- **Namespace** always means a Kubernetes namespace. Vault Community has no
  namespaces; when this repo means Vault Enterprise's, it says "Vault
  namespace".
- **Path** in a policy is the full API path including the mount:
  `team-a/kv/data/dev/team-a-api/web/*`.

## The example, end to end

1. The platform team installs VCO, gives it its Vault login, and installs the
   bootstrap chart once.
1. `team-a` is created. The parent renders a `SecretEngineMount`: Vault now has
   `team-a/kv/`, empty, visible to nobody yet.
1. A developer annotates ServiceAccount `web` in `team-a-api` with
   `vault.stakater.com/kv: "true"` and `vault.stakater.com/role: editor`.
1. The per-tenant chart renders Policy `kv.team-a.team-a-api.web` —
   create, read, update on `team-a/kv/data/dev/team-a-api/web/*` and on its
   namespace's shared folder `team-a/kv/data/dev/_shared/from-team-a-api/*`
   — and a Kubernetes auth role with the same name on
   `auth/team-a/kubernetes/workloads`, bound to `web` in the namespace named
   `team-a-api` that carries `team-a`'s label. The scope check passes: every path starts with `team-a/kv/`.
   It also renders ConfigMap `vault-config-web` with `VAULT_K8S_ROLE`,
   `VAULT_KV_APP_PATH=team-a/kv/data/dev/team-a-api/web/` and the rest.
1. A teammate in `team-a-editors` signs in with OIDC (role `sso.team-a.editor`)
   and writes `postgres` under the app's path.
1. The Deployment carries `vault.stakater.com/kv-secret.db-creds: postgres`.
   ESO logs in as `web`, reads it, and keeps Secret `web-db-creds` in sync.
   Reloader rolls the pods when the value changes.
1. `web` tries `team-b/kv/data/dev/...`: 403. It tries to log in with
   `kv.team-b.team-b-api.api`: refused, wrong ServiceAccount.
1. `team-a` is deleted. Policies, roles and auth mounts go, and every token
   issued through them is revoked; the mount `team-a/kv/` and its secrets stay
   until a Vault admin disables the mount.

## Enterprise and Community, side by side

| | Vault Enterprise extension | This extension |
|---|---|---|
| Tenant boundary | Vault namespace `team-a/` | mount `team-a/kv/` + policies scoped to it |
| Workload auth | `kubernetes/workloads` inside each namespace | `auth/team-a/kubernetes/workloads`, one per tenant |
| SSO | `oidc/sso` inside each namespace | `auth/team-a/oidc/sso`, one per tenant |
| Cross-tenant | Vault namespace `shared/` | mount `shared/kv/` |
| Names | `kv.<tenant>.<ns>.<sa>` | the same |
| ConfigMap keys | `VAULT_NAMESPACE=team-a`, `VAULT_KV_APP_PATH=kv/data/...` | `VAULT_NAMESPACE` empty, `VAULT_KV_APP_PATH=team-a/kv/data/...` |
| Annotations, roles | `vault.stakater.com/*`, four roles | the same |
| What isolates | the namespace, then policies | policies only, checked at render and at admission |
| Per-tenant audit, delegated admin | possible | not possible |
| VCO's reach | one tenant namespace per object | all of root; bounded by name, mount type and admission |
