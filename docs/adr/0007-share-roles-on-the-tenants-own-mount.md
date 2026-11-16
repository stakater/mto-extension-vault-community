# ADR-0007: A tenant is a mount prefix, and its share roles live on its own mount

- **Status:** Accepted
- **Date:** 2026-11-03 (decided by Ayesha Arshad, during story C.2)
- **Supersedes:** ADR-0002

## Context

ADR-0002 made a tenant a mount prefix: `<tenant>/kv`, and auth mounts
`auth/<tenant>/kubernetes/workloads` and `auth/<tenant>/oidc/sso`. It put the
cross-tenant share roles on one more mount, `auth/shared/kubernetes/workloads`,
as Enterprise puts them in the shared Vault namespace.

Porting the tenant chart showed a gap in that placement. The workload contract
gives an app one auth mount, `VAULT_K8S_MOUNT`, and for each share a role and a
Vault namespace (`VAULT_OUT_<PEER>_ROLE`, `VAULT_OUT_<PEER>_NAMESPACE`). On
Enterprise that is enough: the shared namespace has a mount of the same name,
`kubernetes/workloads`. On Community there is no namespace to switch to, and
`VAULT_K8S_MOUNT` names the tenant's own mount, so an app that follows the
contract logs in for a share at the wrong mount. ESO is not affected, because
the chart sets the share SecretStore's `mountPath` itself.

On Community Edition the auth mount is not the wall: a role is bound to its
own ServiceAccount, its namespace by name and tenant label, and its own policy
(A1, Q13). So a share role can live on any mount the tenant owns.

## Decision

A tenant is everything under its name as a prefix: **every Vault path is the
Enterprise path with `<tenant>/` in front**.

- Each tenant gets its **own KV v2 mount at `<tenant>/kv`**, rendered by the
  parent for every valid Tenant (data lifetime = `Tenant` lifetime, as the
  Enterprise `Namespace` CR).
- Each tenant gets its **own auth mounts at `auth/<tenant>/kubernetes/workloads`
  and, with SSO, `auth/<tenant>/oidc/sso`**, rendered by the tenant chart, as
  Enterprise renders `kubernetes/workloads` and `oidc/sso` inside the tenant's
  namespace. They live as long as the tenant has a labelled namespace, and
  disabling them revokes every token issued through them (A6).
- Cross-tenant exchange uses **`shared/kv`**, rendered once by the parent.
  **The share roles live on the tenant's own
  `auth/<tenant>/kubernetes/workloads`**, beside its workload roles. There is
  no shared auth mount.
- Roles keep the Enterprise names (`kv.<tenant>.<ns>.<sa>`,
  `share.<tenant>.…`, `sso.<tenant>.<role>`), which are tenant-qualified.
- Tenant names that would collide with reserved or platform paths, in the
  secrets table or the auth table, are refused (design §5).

## Consequences

- The workload contract is unchanged: a share login uses `VAULT_K8S_MOUNT`
  with `VAULT_OUT_<PEER>_ROLE` or `VAULT_IN_<PEER>_ROLE`, and every
  `VAULT_*_NAMESPACE` is empty.
- Offboarding revokes a tenant's share tokens at once, with its workload
  tokens: they come from the same mount (A6).
- A tenant has its own KV settings (`max_versions`, `cas_required`) (E1) and
  its own auth mount settings (token TTL defaults).
- The full request path `team-a/kv/data/...` is the string Enterprise accepts
  with the namespace in the URL, which keeps the edition move simple.
- Offboarding a tenant's data is one mount disable, by a Vault admin
  (ADR-0005).
- Two or three mounts per tenant, and one shared kv mount. The mount table is
  linear, about 53 bytes per mount, and was measured to 5000 (E4); the auth
  table is separate.
- A tenant can't be named like the first segment of a platform auth mount
  (`kubernetes` for VCO's login, `token`, an admin `oidc`): its auth mounts
  would nest under it (N7).
- With SSO, each tenant's mount has its own UI callback URL, so the IdP client
  needs one redirect URI per tenant or a wildcard. Enterprise avoids this with
  `namespace_in_state`.
- VCO writes share roles on every tenant's mount, so its policy allows
  `share.*` roles on `auth/+/kubernetes/workloads` (ADR-0008); the admission
  policies bind each share role to its own tenant's mount.

## Alternatives

- **Share roles on `auth/shared/kubernetes/workloads`** (ADR-0002). Rejected:
  the contract's `VAULT_K8S_MOUNT` names the tenant's mount, so an app logs in
  for a share at the wrong mount; and offboarding left share tokens alive to
  their TTL.
- **A new ConfigMap key, `VAULT_OUT_<PEER>_K8S_MOUNT`.** Rejected: a contract
  change, which must be made in the Enterprise extension too (ADR-0001), for
  no isolation gained.
- **Document the shared mount for SDK users.** Rejected: the contract would
  say one thing and the mount another.
- **One shared KV mount, `kv/mto/<tenant>/` (the original proposal).**
  Rejected, as in ADR-0002: one set of KV settings for all; every policy
  depends on a prefix that a glob can over-reach; purging one tenant means
  deleting paths inside a shared mount.
- **One shared auth mount for all tenants.** Rejected, as in ADR-0002:
  removing a tenant's roles leaves its tokens alive to their TTL (A6), and in
  root it can't be `auth/kubernetes/workloads` beside VCO's login (N7).
