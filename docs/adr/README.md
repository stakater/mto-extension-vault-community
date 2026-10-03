# Architecture Decision Records

Each ADR records one decision: its context, what we decided, the consequences
(including costs), and the alternatives we rejected and why.

**Convention:** ADRs are immutable once accepted. Don't edit a decided ADR to
reflect a changed mind — write a new ADR that **supersedes** it, and update the
old one's status. This keeps the evolution of decisions legible.

Format: Title · Status · Date · Context · Decision · Consequences · Alternatives.
Facts are cited to `../vault-community-baseline.md` by row.

## Index

| # | Decision | Status |
|---|---|---|
| [0001](0001-port-the-enterprise-extension.md) | Port the Enterprise extension: same contract, same charts shape, VCO CRs; a separate repo for now | Proposed |
| [0002](0002-tenant-is-a-mount-not-a-namespace.md) | A tenant is a KV mount `<tenant>/kv` plus tenant-qualified policies and roles on shared auth mounts | Proposed |
| [0003](0003-policy-is-the-wall-so-check-every-policy.md) | Per-identity policies, never one tenant-wide policy; every rendered policy passes a scope check | Proposed |
| [0004](0004-tenants-never-administer-vault.md) | No tier may manage policies, mounts, auth or identity | Proposed |
| [0005](0005-data-outlives-definitions.md) | Deleting a tenant revokes access and keeps its mount; VCO is denied mount deletion | Proposed |
| [0006](0006-bound-the-operator-by-name.md) | VCO's Vault policy is narrowed by object name, so it can't rewrite itself or the platform | Proposed |

All are Proposed until story C.0 confirms the Vault and VCO behaviour they
rest on.
