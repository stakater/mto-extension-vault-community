# ADR-0002: A tenant is a mount, not a namespace

- **Status:** Proposed
- **Date:** 2026-10-03

## Context

Without namespaces (N1), a tenant's scope must be built from root-level
objects: mounts (N3), policies (P1) and auth roles (A1, A3). Names are global
(N5). The original proposal put every tenant under one shared KV mount, at
`kv/mto/<tenant>/*`, with one policy and one Kubernetes auth role per tenant.

## Decision

- Each tenant gets its **own KV v2 mount at `<tenant>/kv`**, rendered by the
  parent for every valid Tenant (data lifetime = `Tenant` lifetime, as the
  Enterprise `Namespace` CR).
- Cross-tenant exchange uses one **shared mount `shared/kv`**, as the shared
  Vault namespace does on Enterprise.
- Auth mounts are **shared**: one `auth/kubernetes/workloads`, one
  `auth/oidc/sso`, created once by the bootstrap chart. Roles keep the
  Enterprise names (`kv.<tenant>.<ns>.<sa>`, `sso.<tenant>.<tier>`), which are
  already tenant-qualified.
- Tenant names that would collide with reserved or platform paths are refused
  (design §5).

## Consequences

- A tenant has its own KV settings (`max_versions`, `cas_required`) (E1).
- The full request path `team-a/kv/data/...` is the string Enterprise accepts
  with the namespace in the URL, which keeps the edition move simple.
- One mount per tenant grows the mount table; open question 3 measures it.
- Offboarding a tenant's data is one mount disable, by a Vault admin.
- Auth configuration (TTL defaults, issuer) is install-wide, not per tenant.

## Alternatives

- **One shared KV mount, `kv/mto/<tenant>/` (the proposal).** Rejected: one
  set of KV settings for all; every policy depends on a prefix that a glob can
  over-reach (`kv/data/mto/team*`); purging one tenant means deleting paths
  inside a shared mount instead of disabling a mount.
- **A Kubernetes and an OIDC auth mount per tenant.** Rejected for v1: a
  mount and a config per tenant, an IdP redirect URI per tenant mount, and no
  isolation gained — roles are bound to their ServiceAccount or group either
  way (A1, A3).
