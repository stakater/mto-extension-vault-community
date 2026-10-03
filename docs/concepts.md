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
| **Login role** | Vault, `auth/kubernetes/workloads` or `auth/oidc/sso` | A Kubernetes auth role per annotated ServiceAccount, or an OIDC role per tenant tier. Same name as its policy. |
| **Scope check** | render tests | The rule that every path in every policy rendered for a tenant stays inside that tenant's mount or its named shares. The Community Edition substitute for a namespace wall. |
| **Tier** | annotation or identity-provider group | `audit-read`, `viewer`, `editor`, `admin`. Workloads get it from `vault.stakater.com/tier`; people from the group `<tenant>-<tier>s`. |
| **VCO** | the cluster | vault-config-operator: turns `Policy`, `SecretEngineMount`, auth role CRs into Vault configuration. Logs in with its own role. |
| **Template Operator** | Stakater | Renders the per-tenant chart once per tenant. |
| **Bootstrap chart** | this repo | Installed once per cluster. Watches tenants, renders each tenant's mount, the shared mount and the shared auth mounts. |
| **Per-tenant chart** | this repo | Pulled and rendered by Template Operator per tenant: policies, roles, ConfigMaps, ESO objects. Never installed by hand. |

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
   `vault.stakater.com/kv: "true"` and `vault.stakater.com/tier: editor`.
1. The per-tenant chart renders Policy `kv.team-a.team-a-api.web` —
   create, read, update on `team-a/kv/data/dev/team-a-api/web/*`, read on
   `team-a/kv/data/dev/_shared/*`, write on `team-a/kv/data/dev/_shared/from-team-a-api/*`
   — and a Kubernetes auth role with the same name, bound to `web` in
   `team-a-api`. The scope check passes: every path starts with `team-a/kv/`.
   It also renders ConfigMap `vault-config-web` with `VAULT_K8S_ROLE`,
   `VAULT_KV_APP_PATH=team-a/kv/data/dev/team-a-api/web/` and the rest.
1. A teammate in `team-a-editors` signs in with OIDC (role `sso.team-a.editor`)
   and writes `postgres` under the app's path.
1. The Deployment carries `vault.stakater.com/kv-secret.db-creds: postgres`.
   ESO logs in as `web`, reads it, and keeps Secret `web-db-creds` in sync.
   Reloader rolls the pods when the value changes.
1. `web` tries `team-b/kv/data/dev/...`: 403. It tries to log in with
   `kv.team-b.team-b-api.api`: refused, wrong ServiceAccount.
1. `team-a` is deleted. Policies and roles go; the mount `team-a/kv/` and its
   secrets stay until a Vault admin disables the mount.

## Enterprise and Community, side by side

| | Vault Enterprise extension | This extension |
|---|---|---|
| Tenant boundary | Vault namespace `team-a/` | mount `team-a/kv/` + policies scoped to it |
| Workload auth | `kubernetes/workloads` inside each namespace | one shared `kubernetes/workloads` |
| SSO | `oidc/sso` inside each namespace | one shared `oidc/sso` |
| Cross-tenant | Vault namespace `shared/` | mount `shared/kv/` |
| Names | `kv.<tenant>.<ns>.<sa>` | the same |
| ConfigMap keys | `VAULT_NAMESPACE=team-a`, `VAULT_KV_APP_PATH=kv/data/...` | `VAULT_NAMESPACE` empty, `VAULT_KV_APP_PATH=team-a/kv/data/...` |
| Annotations, tiers | `vault.stakater.com/*`, four tiers | the same |
| What isolates | the namespace, then policies | policies only, checked at render |
| Per-tenant audit, auth config, delegated admin | possible | not possible |
