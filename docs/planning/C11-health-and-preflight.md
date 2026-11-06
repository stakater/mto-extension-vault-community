# C.11 — Health and preflight

Story: `docs/roadmap.md` C.11 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-OPS-1, AC-OPS-2.

## Why (one paragraph)

When VCO can't write a tenant's object, the platform team must see it on the
Kubernetes side, on that tenant only, without reading Vault. On Community
Edition the commonest cause is a mount collision: a tenant named like a
platform mount the reserved list misses. The Template outputs were ported in
C.1; this story ports the optional alert, proves the outputs live for a
collision, and keeps the preflight that refuses the wrong edition.

## Governing constraints

- Design §8: VCO's status can't say "healthy now"; the outputs say "ever
  succeeded" and "last error ever" (V5, T1); a TemplateInstance's own `Ready`
  does not reflect VCO.
- Design §5: a name the reserved list misses fails in Vault with a 400 on
  that tenant's CRs alone; no other tenant is affected (N3, N7, Q5b).
- ADR-0001: the alert is the Enterprise one, renamed.

## Design

- `templates/09-monitoring.yaml`: Enterprise's PrometheusRule (off by
  default), `mto-extension-vault-community-<tenant>`, one alert on the
  tenant's ExternalSecrets failing to sync, selecting the tenant's namespaces.
- `hack/contract-delta.txt` becomes empty: the contract equals Enterprise's.
- e2e: a step that mounts `e2e-plat/` (secrets) and `auth/e2e-plat/` (auth)
  as root — a platform the reserved list does not know — and creates tenant
  `e2e-plat`. Its kv mount and auth mount fail in Vault; the parent's
  `enginesLastError` and the child's `authMountsLastError` and
  `k8sAuthRolesLastError` name the error for that tenant's objects; every
  other tenant's entries stay empty and `web` still logs in. The preflight
  (refuses Enterprise, C.2) stays.

## Tests (red first)

Render: `alertlabels` (the alert selects only labels ESO exports, and the
tenant's namespaces), `falsestring` and `rbacgate` for `monitoring.enabled`,
`contract` with an empty delta.

Live: the collision step above (AC-OPS-1, AC-OPS-2).

## Out of scope

An alert on VCO objects: VCO's status can't say "healthy now", and a CR that
never succeeded has no condition for a rule to match (Enterprise's finding).

## Done means

The roadmap Done line; `make verify` green; e2e green; `charts/README.md`
"Health" and "Monitoring" written; story marked ✅ with this doc linked.
