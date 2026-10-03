# ADR-0004: Tenants never administer Vault

- **Status:** Proposed
- **Date:** 2026-10-03

## Context

On Enterprise, a namespace admin can manage policies and mounts inside their
own namespace without reaching anyone else. On Community Edition every policy,
mount and auth role sits in the one root namespace beside every other tenant's
(N1, N5). A tenant allowed to write a policy could write one that reads another
tenant; a tenant allowed to mount an engine could shadow a path.

## Decision

- No tier — workload or person, including `admin` — may write `sys/policy`,
  `sys/mounts`, `sys/auth`, `auth/*/role`, `auth/*/config` or `identity/*`.
  The scope check (ADR-0003) makes this mechanical.
- Tenants get their secrets; the platform keeps Vault.

## Consequences

- No self-service policy authoring, no tenant-mounted engines on Community
  Edition. A tenant needing that is a tenant needing Enterprise or OpenBao —
  said plainly in the deck and the docs.
- New capabilities reach tenants only as extension features (annotations),
  reviewed once for all tenants.

## Alternatives

- **Delegated policy authoring under a prefix.** Rejected: a policy can name
  any path; Vault doesn't confine a policy's paths to its name.
- **Tenant-owned engine mounts under `<tenant>/`.** Rejected for v1: mount
  creation needs `sys/mounts` with sudo-level reach; Transit and PKI come as
  extension features instead (C.12, C.13).
