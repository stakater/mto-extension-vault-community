# C.9 — Lifecycle that keeps data

Story: `docs/roadmap.md` C.9 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-LIFE-2, AC-LIFE-3, AC-LIFE-4, AC-LIFE-5, AC-ACC-5.

## Why (one paragraph)

Access must end at once when it is taken away, and data must survive every
mistake short of a deliberate purge. The charts already place data and grants
apart (C.1: the parent renders the kv mount; C.2: the tenant chart renders the
auth mount). This story proves the lifecycle live, under the production VCO
policy, and documents the admin purge in its safe order. On Community Edition
it also proves what ADR-0007 bought: disabling a tenant's auth mount revokes
every token issued through it.

## Governing constraints

- ADR-0005: data outlives definitions; VCO has no delete on kv mounts; purge is
  a Vault-admin act.
- ADR-0007, A6: the tenant's auth mounts go with its last labelled namespace,
  and disabling a mount revokes its tokens — share tokens included.
- V12: never disable a kv mount whose CR is live: VCO re-creates it empty.
- Design §7: the lifecycle table and the purge order.
- Enterprise e2e rule: a denial is a 403 with a matching allow; a refusal of a
  deleted role is "invalid role name".

## Design

No chart change. The e2e suite gains, ported from Enterprise and changed for
paths:

- role change (AC-ACC-5): `lower` from editor to viewer; the policy is
  rewritten in place; the token issued at editor loses write at once.
- removal (AC-LIFE-3): `temp`'s annotation dropped; policy, role and ConfigMap
  go; a token issued before loses access; a new login is refused.
- lifetime (AC-LIFE-2, AC-LIFE-5): e2e-beta's last labelled namespaces deleted;
  its child TIs and grants go, its auth mount is disabled and a token issued
  before is revoked (A6); `e2e-beta-kv` and the secret stay across a drift
  period; a labelled namespace brings the grants back, and the workload reads
  the retained secret — the adoption a reused name shows.
- offboarding (AC-LIFE-4): with the production policy swapped in, the Tenant
  deleted with its namespaces; every grant goes, e2e-alpha's share role to it
  too; `e2e-beta-kv` stays Terminating with its data and the shares in
  `shared/kv`; VCO's own login is refused the mount's disable; then the
  documented purge: disable the mount as root, remove the finalizer.

`charts/README.md` gains "Deletion" (the lifecycle table) and "Uninstall"
(the documented order).

## Tests (red first)

The four steps fail before the fixture ServiceAccounts `lower` and `temp`
exist and before the production-policy swap; each refusal has its allow.

## Out of scope

Automated purge; a retention period.

## Done means

The roadmap Done line; `make verify` green; e2e green with the four steps;
README sections written; story marked ✅ with this doc linked.
