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
| [0001](0001-port-the-enterprise-extension.md) | Port the Enterprise extension: same contract, same charts shape, VCO CRs; a separate repo for now | Accepted |
| [0002](0002-tenant-is-a-mount-not-a-namespace.md) | A tenant is a mount prefix: `<tenant>/kv` and auth mounts `auth/<tenant>/…`, the Enterprise paths with the tenant in front | Accepted |
| [0003](0003-policy-is-the-wall-so-check-every-policy.md) | Per-identity policies, never one tenant-wide policy; every rendered policy and role passes a scope check, also at admission | Accepted |
| [0004](0004-tenants-never-administer-vault.md) | No role may manage policies, mounts, auth or identity | Accepted |
| [0005](0005-data-outlives-definitions.md) | Deleting a tenant revokes access and keeps its mount; VCO is denied mount deletion | Accepted |
| [0006](0006-bound-the-operator-by-name.md) | VCO's Vault policy is narrowed by object name and mount type; what VCO is asked is bounded at admission | Accepted |

All were accepted on 2026-11-03, after story C.0 confirmed the Vault and VCO
behaviour they rest on (`spikes/c0-findings.md`).
