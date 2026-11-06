# ADR-0002: A tenant is a mount prefix, not a namespace

- **Status:** Superseded by ADR-0007
- **Date:** 2026-10-03; revised 2026-11-02 after story C.0; accepted 2026-11-03

## Context

Without namespaces (N1), a tenant's scope must be built from root-level
objects: mounts (N3), policies (P1) and auth roles (A1, A3). Names are global
(N5). The original proposal put every tenant under one shared KV mount, at
`kv/mto/<tenant>/*`, with one policy and one Kubernetes auth role per tenant.

On Enterprise and in OpenBao's default mode, a tenant is a namespace that
holds its KV mount and its own auth mounts (`kubernetes/workloads`,
`oidc/sso`); the tenant chart renders the auth mounts, and offboarding
disables them. OpenBao's single-namespace "path" mode shares one auth mount and
calls its isolation "soft".

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
- Cross-tenant exchange uses **`shared/kv`**, with share roles on
  **`auth/shared/kubernetes/workloads`**, rendered once by the parent, as the
  shared Vault namespace does on Enterprise.
- Roles keep the Enterprise names (`kv.<tenant>.<ns>.<sa>`,
  `share.<tenant>.…`, `sso.<tenant>.<role>`), which are tenant-qualified.
- Tenant names that would collide with reserved or platform paths, in the
  secrets table or the auth table, are refused (design §5).

## Consequences

- A tenant has its own KV settings (`max_versions`, `cas_required`) (E1) and
  its own auth mount settings (token TTL defaults).
- The full request path `team-a/kv/data/...` is the string Enterprise accepts
  with the namespace in the URL, which keeps the edition move simple.
  `VAULT_K8S_MOUNT` is Enterprise's value with the tenant prefix
  (`team-a/kubernetes/workloads`); the ConfigMap keys are unchanged.
- Offboarding revokes the tenant's tokens at once (A6). Offboarding its data is
  one mount disable, by a Vault admin (ADR-0005).
- Two or three mounts per tenant. The mount table is linear, about 53 bytes per
  mount, and was measured to 5000 (E4); the auth table is separate.
- A tenant can't be named like the first segment of a platform auth mount
  (`kubernetes` for VCO's login, `token`, an admin `oidc`): its auth mounts
  would nest under it (N7).
- With SSO, each tenant's mount has its own UI callback URL, so the IdP client
  needs one redirect URI per tenant or a wildcard. Enterprise avoids this with
  `namespace_in_state`.

## Alternatives

- **One shared KV mount, `kv/mto/<tenant>/` (the proposal).** Rejected: one
  set of KV settings for all; every policy depends on a prefix that a glob can
  over-reach (`kv/data/mto/team*`); purging one tenant means deleting paths
  inside a shared mount instead of disabling a mount.
- **One shared auth mount for all tenants** (this ADR's first text:
  `auth/kubernetes/workloads` and `auth/oidc/sso`). Not possible as written:
  Vault refuses `auth/kubernetes/workloads` beside VCO's login at
  `auth/kubernetes` (N7). C.0's first run moved it to `auth/mto/workloads` and
  `auth/mto/sso`. Rejected: removing a tenant's roles leaves its tokens alive
  to their TTL, up to 4 h (A6); it departs from Enterprise, where the tenant
  chart owns the tenant's auth mounts; and it needs a prefix of its own.
  Isolation is the same either way: roles are bound to their ServiceAccount
  or group (A1, A3).
