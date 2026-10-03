# Roadmap

Phases → milestones → user stories. **Every story delivers a demo-able outcome.**

## How we work

- **Story format:** *As a `<role>`, I want `<capability>`, so that `<value>`.*
  Every story has a **Done:** line and cites the acceptance scenarios it
  satisfies (`acceptance.md`, e.g. **AC-ISO-1**).
- **Lifecycle:** **📝 Draft** (written, not agreed — may be re-scoped or killed)
  → **👍 Approved** (a human said build it) → **🔨 In progress** → **✅ Done**
  (Done line met, `make` green, planning doc linked). Nothing moves from Draft
  to In progress without explicit approval.
- **One story at a time**, end to end. Walking skeleton first: one tenant, one
  workload, one secret delivered, isolated and proven, then thicken.
- **Port, don't redesign.** Each story starts from the matching Enterprise
  chart code and tests and changes only what §2 of `design.md` names.
- The method: `method.md`.

## Phases

| Phase | Demo outcome |
|---|---|
| **0 · Prove the ground** | Every open question in `vault-community-baseline.md` answered on a live Vault Community 2.1.1 with VCO v1.0.3; ADRs moved to Accepted or superseded. |
| **1 · Walking skeleton** | Tenant created → `team-a/kv/` appears → a ServiceAccount annotated → its policy passes the scope check → ESO delivers a Secret to the pod; the same workload is refused `team-b/kv/`; VCO is refused a write to its own policy. |
| **2 · Trustworthy** | SSO tiers, sharing inside and across tenants, lifecycle that keeps data, Reloader rotation, health — ready for a design partner. |
| **3 · Complete and convergent** | Transit and PKI as the Enterprise extension gains them; per-tenant audit recipe; the decision on one two-mode extension; the migration runbook to Enterprise. |

---

## Phase 0 — Prove the ground

**Story C.0 — Live-install spike** 📝 *Draft*

As the engineer porting the extension, I want every open Vault Community and
VCO question answered on a live install, so that the port rests on observed
behaviour.

Done: all twelve open questions answered with evidence in
`docs/spikes/c0-findings.md`, using the Enterprise repo's lab with
`VAULT_EDITION=ce`; each ADR Accepted or superseded; `design.md` updated where
an answer changed it. Planning:
[`planning/C0-live-install-spike.md`](planning/C0-live-install-spike.md).

---

## Phase 1 — Walking skeleton

**Story C.1 — Bootstrap fans out, tenant mounts appear** 📝 *Draft*

As a platform team, I want to install the extension once and have every tenant
get its own KV mount, so that no tenant needs a setup step.

Done: bootstrap chart ported; parent renders `<tenant>/kv` per valid Tenant,
`shared/kv` and the shared auth mounts once; reserved and invalid names skipped
and listed; no `Namespace` CR and no `targetNamespace` anywhere (render test);
`make` runs lint, version checks, render tests, CRD validation against vendored
VCO v1.0.3 CRDs. Satisfies **AC-LIFE-1**, **AC-ISO-8**.

**Story C.2 — Workload access with the scope check** 📝 *Draft*

As an application team, I want a ServiceAccount annotation to give my app its
own secrets and nothing else, so that two apps — and two tenants — can never
read each other.

Done: per-ServiceAccount Policy and Kubernetes auth role on the shared mount,
names identical to Enterprise; the scope check in `_helpers.tpl` and the
`policyscope` render check, mutation-tested; `vault-config-<sa>` with
`VAULT_NAMESPACE` empty and mount-prefixed paths; live: own prefix read and
write, sibling and other tenant refused (403 paired with an allow). Satisfies
**AC-ISO-1..5**, **AC-ACC-1..4**.

**Story C.3 — VCO can't widen itself** 📝 *Draft*

As a security owner, I want the operator that writes tenant policies unable to
touch its own policy, the platform's policies or any mount's data, so that the
most powerful identity in the design is bounded.

Done: `charts/examples/vco-admin-policy.hcl` (design §6); live: VCO refused a
write to `sys/policy/vco-admin` and `default`, refused a mount delete; the
render never emits a policy name outside the three families. Satisfies
**AC-ISO-7**, **AC-LIFE-4**.

**Story C.4 — Delivery through External Secrets Operator** 📝 *Draft*

As an application team, I want a Deployment annotation to become a Kubernetes
Secret, so that my code never calls Vault.

Done: slice `eso` ported with `path: <tenant>/kv` and no namespace; live: the
pod sees the value. Satisfies **AC-DEL-1**.

**Story C.5 — Contract parity with Enterprise** 📝 *Draft*

As a platform team that may move editions, I want the annotations, tiers,
names and ConfigMap keys to be exactly the Enterprise extension's, so that
moving a tenant never changes a workload.

Done: a render check compares this chart's contract against the pinned
Enterprise chart's (annotation keys, tier names, name families, ConfigMap key
set minus `VAULT_NAMESPACE` value); fails on any drift. Satisfies
**AC-PAR-1**.

> **Phase 1 demo:** create `team-a` and `team-b`; annotate `web`; deliver
> `postgres` to the pod; show `web` refused on `team-b/kv/`; show VCO refused
> on `sys/policy/vco-admin`.

---

## Phase 2 — Trustworthy

**Story C.6 — Human SSO in four tiers** 📝 *Draft* — one shared `oidc/sso`
mount, role `sso.<tenant>.<tier>` bound to group `<tenant>-<tier>s`; live
through Dex and Keycloak as in Enterprise. Satisfies **AC-ISO-6**,
**AC-ACC-5**, **AC-ACC-6**.

**Story C.7 — Sharing inside a tenant** 📝 *Draft* — `_shared/from-<ns>/` and
`kv-subscribe-ns`, under the tenant mount. Satisfies **AC-SHR-1**,
**AC-SHR-2**.

**Story C.8 — Sharing across tenants** 📝 *Draft* — `shared/kv/`,
`from-<a>/to-<b>/`, export and import annotations; the scope check's shared
rule. Satisfies **AC-SHR-3**.

**Story C.9 — Lifecycle that keeps data** 📝 *Draft* — last namespace
unlabelled, tenant deleted, tenant recreated; the admin purge procedure.
Satisfies **AC-LIFE-2..5**.

**Story C.10 — Rotation reaches the pod** 📝 *Draft* — Reloader annotation;
live rotation. Satisfies **AC-DEL-2**.

**Story C.11 — Health and preflight** 📝 *Draft* — outputs ported; mount
collisions surfaced; e2e preflight refuses Enterprise. Satisfies
**AC-OPS-1**, **AC-OPS-2**.

---

## Phase 3 — Complete and convergent

**Story C.12 — Transit per tenant** 📝 *Draft* — `<tenant>/transit`, ported
when the Enterprise extension has it.

**Story C.13 — PKI per tenant** 📝 *Draft* — `<tenant>/pki`, ported when the
Enterprise extension has it.

**Story C.14 — Per-tenant audit recipe** 📝 *Draft* — filtering the one audit
log by `<tenant>/` downstream, documented and tested.

**Story C.15 — One extension, two editions?** 📝 *Draft* — decide, with C.5's
evidence, whether to merge this chart into the Enterprise one behind
`isolation.strategy: path | namespace` (the original proposal), or keep two
repos.

**Story C.16 — Moving a tenant to Enterprise** 📝 *Draft* — runbook, after
C.0 question 8, for moving `<tenant>/kv` into Vault namespace `<tenant>`
without changing a workload.

---

## Not on the roadmap (non-goals)

Emulating Vault namespaces · tenant-managed policies or mounts · per-tenant
quotas beyond Community Edition's · provisioning Vault. See `vision.md`.
