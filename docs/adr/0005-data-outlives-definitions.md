# ADR-0005: Data outlives definitions

- **Status:** Proposed
- **Date:** 2026-10-03

## Context

Disabling a mount deletes its data (E2). VCO has no deletion policy: deleting
a `SecretEngineMount` CR disables the mount (V3). The Enterprise extension keeps
data by rendering the data-bearing CRs from the parent (Tenant lifetime) and by
denying VCO the delete in Vault; its e2e suite proves it.

## Decision

- The tenant mount is rendered by the **parent**, so it lives as long as the
  `Tenant`, not as long as the tenant's namespaces.
- VCO's Vault policy has **no `delete` on `sys/mounts/+/kv`** (ADR-0006). A
  deleted mount CR stays `Terminating`; the data stays.
- Grants (policies, roles) are deleted normally: offboarding revokes access.
- Purge is a documented Vault-admin act: `vault secrets disable <tenant>/kv`,
  then remove the CR's finalizer; for shares, delete `from-<t>/` and `to-<t>/`
  in `shared/kv`.

## Consequences

- A mistaken `kubectl delete tenant` loses no secret.
- A recreated tenant with the same name adopts the old mount and its data —
  documented, with the purge steps (AC-LIFE-5).
- Stuck `Terminating` CRs after offboarding are the intended signal, not a bug.

## Alternatives

- **Let VCO delete the mount.** Rejected: one wrong delete destroys every secret
  of a tenant; Vault can't restore a disabled mount.
- **Keep everything forever.** Rejected: offboarding needs a real purge.
