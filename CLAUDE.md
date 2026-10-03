# CLAUDE.md

Guidance for working in this repository.

## What this is

**The Vault Community Edition extension for the Multi-Tenant Operator.** It
gives every Multi-Tenant Operator `Tenant` a secret scope in one shared Vault
Community — its own KV mount, a policy and login role per annotated
ServiceAccount, SSO in four tiers, opt-in sharing — with no per-tenant manual
work. Community Edition has no namespaces, so a tenant is a mount path plus
policies plus auth roles, not a Vault namespace.

It is a **port of `stakater-ab/mto-extension-vault-enterprise`**: the same Helm
charts shape, the same vault-config-operator (VCO) CRs, and the same workload
contract (annotations, tiers, names, ConfigMap keys). `docs/design.md` §2 lists
the only three differences.

## Status: design phase — no code yet

This repo holds **requirements and design only**. No chart, no Makefile, no
tests yet. Every story is 📝 Draft until a human approves it. The first story
is **C.0, a live-install spike** on Vault Community — do it before porting any
chart.

## Invariants — never violate these

1. **Every rendered policy passes the scope check** (design §4, ADR-0003): every
   path inside the tenant's mount `<tenant>/kv/` or its named shares in
   `shared/kv/`; the tenant segment closed by `/` before any wildcard; no `+`;
   nothing under `sys/`, `auth/`, `identity/`, `cubbyhole/`. A policy that fails
   it must fail the render.
1. **Every name is tenant-qualified** in one of the Enterprise name families
   (`kv.` 4 parts, `share.` 6, `sso.` 3). Community Edition has one namespace;
   an unqualified name collides across tenants (baseline N2).
1. **No `Namespace` CR and no `targetNamespace`** anywhere.
1. **Tenants never administer Vault** (ADR-0004): no tier writes policies,
   mounts, auth or identity.
1. **VCO is bounded by name** (ADR-0006): it can't write a policy outside the
   three families, can't touch `auth/kubernetes`, can't delete a mount.
1. **Data outlives definitions** (ADR-0005): the tenant mount is rendered by the
   parent; VCO is denied mount deletion; purge is a Vault-admin act.
1. **Contract parity with Enterprise** (ADR-0001): a change to annotations,
   tiers, names or ConfigMap keys is made in both repos or not at all.

## Legacy — do not model on these

The Vault (`IntegrationConfig`) and ArgoCD (`Extensions` CR) integrations in
tenant-operator are legacy and being removed, including the KV-path-per-tenant
Vault integration. Never read, cite or copy them. The models are
`mto-extension-vault-enterprise` and `mto-extension-openbao`.

## Documentation map

| Doc | What it is |
|---|---|
| `docs/vision.md` | **Read first.** Why this exists, for whom, the value, non-goals. |
| `docs/concepts.md` | Terms, the running example, and Enterprise vs Community side by side. |
| `docs/method.md` | How this is built: story → plan → red → green → verify → validate. |
| `docs/roadmap.md` | Phases and user stories with lifecycle status. |
| `docs/acceptance.md` | The isolation contract as testable scenarios. |
| `docs/design.md` | The delta from Enterprise: rendered objects, the scope check, tenant names, VCO's policy, lifecycle, limits. |
| `docs/vault-community-baseline.md` | What Vault Community 2.1.1 and VCO v1.0.3 give tenancy, with sources; open questions. |
| `docs/diagrams.md` | C4 and sequence diagrams. |
| `docs/adr/` | Architecture Decision Records. |
| `docs/planning/` | One planning doc per story, from `TEMPLATE.md`. |

**ADRs are immutable once accepted.** Supersede, don't edit.

## Workflow for any change (in order)

1. **Story** in `docs/roadmap.md`, 📝 Draft until a human approves.
1. **Planning doc** from `docs/planning/TEMPLATE.md`, committed first.
1. **Red first.** A failing render check or e2e assertion, then the change.
1. **Verify.** `make` green (once it exists), docs updated in the same change,
   story marked ✅ with the planning doc linked.

## Conventions inherited from mto-extension-vault-enterprise

Read its `CLAUDE.md`; every rule there applies once the charts land — the test
harness rules (no check that can pass on its own failure, mutation-test every
guard), the e2e rules (assert as the workload, a denial is a 403 with a
matching allow), dot-joined names, quoted tenant-derived values, toggles only
through `vault.on`, `tenantValues` as the only path to a tenant chart value,
version bumps, vendored VCO CRDs.

## Boundaries

- Baseline: Vault Community **2.1.1**, VCO **v1.0.3**. When either changes,
  update `docs/vault-community-baseline.md` first, then the design.
- Secrets by reference only. No token, unseal key or client secret in any file.
- Feature branches only; PRs cite the story code.
