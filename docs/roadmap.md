# Roadmap

Phases → milestones → user stories. **Every story delivers a demo-able outcome.**

## How we work

- **Story format:** *As a `<role>`, I want `<capability>`, so that `<value>`.*
  Every story has a **Done:** line and cites the acceptance scenarios it
  satisfies (`acceptance.md`, e.g. **AC-ISO-1**).
- **Lifecycle:** **📝 Draft** (written, not agreed — may be re-scoped or killed)
  → **👍 Approved** (a human said build it) → **🔨 In progress** → **✅ Done**
  (Done line met, `make verify` green, planning doc linked). Nothing moves from Draft
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
| **2 · Trustworthy** | SSO roles, sharing inside and across tenants, lifecycle that keeps data, Reloader rotation, health — ready for a design partner. |
| **3 · Complete and convergent** | Transit and PKI as the Enterprise extension gains them; per-tenant audit recipe; the decision on one two-mode extension; the migration runbook to Enterprise. |

---

## Phase 0 — Prove the ground

**Story C.0 — Live-install spike** ✅ *Done*

As the engineer porting the extension, I want every open Vault Community and
VCO question answered on a live install, so that the port rests on observed
behaviour.

Done: the open questions answered with evidence in
[`spikes/c0-findings.md`](spikes/c0-findings.md), on a live Vault Community
2.1.1 with VCO v1.0.3 (question 8 not needed: the extension is Community
only), and the design verified against the Enterprise and OpenBao extensions
for least privilege and isolation (questions 13 to 19); ADRs 0001 to 0006
Accepted on 2026-11-03; `design.md` updated where an answer changed it.
Planning:
[`planning/C0-live-install-spike.md`](planning/C0-live-install-spike.md).

---

## Phase 1 — Walking skeleton

C.1 to C.11 and DX.2 approved by Ayesha Arshad on 2026-11-03.

**Story C.1 — Bootstrap fans out, tenant mounts appear** ✅ *Done*

As a platform team, I want to install the extension once and have every tenant
get its own KV mount, so that no tenant needs a setup step.

Done: bootstrap chart ported; parent renders `<tenant>/kv` per valid Tenant,
`shared/kv` once (and, until ADR-0007, `auth/shared/kubernetes/workloads`); reserved and invalid
names (secrets and auth tables) skipped and listed; no `Namespace` CR and no `targetNamespace` anywhere (render test);
`make` runs lint, version checks, render tests, CRD validation against vendored
VCO v1.0.3 CRDs. Satisfies **AC-LIFE-1**, **AC-ISO-8**. Planning:
[`planning/C1-bootstrap-fans-out.md`](planning/C1-bootstrap-fans-out.md).

**Story C.2 — Workload access with the scope check** ✅ *Done*

As an application team, I want a ServiceAccount annotation to give my app its
own secrets and nothing else, so that two apps — and two tenants — can never
read each other.

Done: the tenant's auth mount `auth/<tenant>/kubernetes/workloads` and its
config; per-ServiceAccount Policy and Kubernetes auth role on it, names
identical to Enterprise, each role bound by namespace name and tenant label;
the scope check (policies and roles) in `_helpers.tpl` and the `policyscope`
render check, mutation-tested; `vault-config-<sa>` with
`VAULT_NAMESPACE` empty and mount-prefixed paths; live: own prefix read and
write, sibling and other tenant refused (403 paired with an allow); a reused
namespace name refused. Satisfies **AC-ISO-1..5**, **AC-ISO-10**,
**AC-ACC-1..4**. Planning:
[`planning/C2-workload-access-scope-check.md`](planning/C2-workload-access-scope-check.md).

**Story C.3 — VCO can't widen itself** ✅ *Done*

As a security owner, I want the operator that writes tenant policies unable to
touch its own policy, the platform's policies or any mount's data, so that the
most powerful identity in the design is bounded.

Done: `charts/examples/vco-admin-policy.hcl` (design §6, mount types
pinned); the bootstrap chart's admission policies on VCO CRs (design §4);
live: VCO refused a write to `sys/policy/vco-admin` and `default`, a mount of
the wrong type and a mount delete; a `kv.*` Policy granting outside its tenant
refused at admission; a tenant's Template refused writing into
`vault-config`; the render never emits a policy name outside the three
families. Satisfies **AC-ISO-7**, **AC-ISO-11**, **AC-ISO-12**,
**AC-LIFE-4**. Planning:
[`planning/C3-vco-cant-widen-itself.md`](planning/C3-vco-cant-widen-itself.md).

**Story C.4 — Delivery through External Secrets Operator** ✅ *Done*

As an application team, I want a Deployment annotation to become a Kubernetes
Secret, so that my code never calls Vault.

Done: slice `eso` ported with `path: <tenant>/kv` and no namespace; live: the
pod sees the value. Satisfies **AC-DEL-1**. Planning:
[`planning/C4-delivery-through-eso.md`](planning/C4-delivery-through-eso.md).

**Story C.5 — Contract parity with Enterprise** ✅ *Done*

As a platform team that may move editions, I want the annotations, roles,
names and ConfigMap keys to be exactly the Enterprise extension's, so that
moving a tenant never changes a workload.

Done: a render check compares this chart's contract against the pinned
Enterprise chart's (annotation keys, role names, name families, ConfigMap key
set minus `VAULT_NAMESPACE` value); fails on any drift. Satisfies
**AC-PAR-1**. Planning:
[`planning/C5-contract-parity.md`](planning/C5-contract-parity.md).

> **Phase 1 demo:** create `team-a` and `team-b`; annotate `web`; deliver
> `postgres` to the pod; show `web` refused on `team-b/kv/`; show VCO refused
> on `sys/policy/vco-admin`; show a `kv.*` Policy granting `path "*"` refused
> at admission.

---

## Phase 2 — Trustworthy

**Story C.6 — Human SSO in four roles** ✅ *Done*

As a person in a tenant, I want to sign in to Vault with my identity-provider
group and get my tenant's access at my role, so that nobody hands out tokens.

Done: `06-oidc-auth.yaml` and `07-sso-policies.yaml` ported: an OIDC mount per
tenant at `auth/<tenant>/oidc/sso`, policy and role `sso.<tenant>.<role>`
bound to exactly the group `<tenant>-<role>s`; `sso.tenantRoleMapping.fallback`
refused at render; the identity provider's redirect URI per tenant mount
verified; live through Keycloak and Dex: each role logs in for its own group
in its own tenant only, gets its role's capabilities, and can't administer
Vault; a person removed from the group can't log in again. Satisfies
**AC-ISO-6**, **AC-ISO-9**, **AC-ACC-1..4** (people), **AC-ACC-6**. Planning:
[`planning/C6-human-sso.md`](planning/C6-human-sso.md).

**Story C.7 — Sharing inside a tenant** ✅ *Done*

As an application team, I want apps in one namespace, and subscribed
namespaces of my tenant, to share secrets through one folder, so that sharing
is explicit and read-only for readers.

Done: the `_shared/from-<ns>/` grants and `kv-subscribe-ns` under the tenant
mount, read-only for subscribers on data and metadata; the `kv-subscribe.<name>`
Deployment annotation; live: `web` writes, `jobs` and a subscribed namespace
read, an unsubscribed namespace is refused. Satisfies **AC-SHR-1**,
**AC-SHR-2**. Planning:
[`planning/C7-sharing-inside-a-tenant.md`](planning/C7-sharing-inside-a-tenant.md).

**Story C.8 — Sharing across tenants** ✅ *Done*

As an application team, I want to export secrets to a named peer tenant, and a
peer to import them, so that two tenants exchange data without reaching each
other's mounts.

Done: share-out and share-in policies and roles on the tenant's own
`auth/<tenant>/kubernetes/workloads` (ADR-0007), paths
`shared/kv/<env>/from-<a>/to-<b>/`;
the share direction in the scope check and the admission policies; the
`kv-import.<name>` Deployment annotation with its share SecretStore; live: the
exporter writes, the importer reads through ESO, the reverse direction and a
third tenant are refused. Satisfies **AC-SHR-3**. Planning:
[`planning/C8-sharing-across-tenants.md`](planning/C8-sharing-across-tenants.md).

**Story C.9 — Lifecycle that keeps data** 👍 *Approved*

As a platform team, I want offboarding to revoke access at once and keep the
data, so that a mistaken delete never loses secrets.

Done: live under the production VCO policy: last namespace unlabelled (grants
gone, data kept); annotation removed (policy and role gone); tenant deleted
(its auth mounts disabled, tokens revoked, `<tenant>/kv` kept); tenant
recreated (it adopts the retained data, visible); the admin purge order
documented in `charts/README.md`. Satisfies **AC-LIFE-2..5**, **AC-ACC-5**.

**Story C.10 — Rotation reaches the pod** 👍 *Approved*

As an application team, I want a new secret version to reach my pod without a
manual restart, so that rotation is routine.

Done: the Reloader annotation documented; live: a new version written in Vault
reaches a new pod through ESO and Reloader. Satisfies **AC-DEL-2**.

**Story C.11 — Health and preflight** 👍 *Approved*

As a platform team, I want each tenant's Vault state and errors visible on the
Kubernetes side, so that a failure is found without reading Vault.

Done: the Template outputs and the optional PrometheusRule ported; a mount
collision surfaces on its own tenant only; the e2e preflight refuses Vault
Enterprise. Satisfies **AC-OPS-1**, **AC-OPS-2**.

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

**Story C.16 — Moving a tenant to Enterprise** 📝 *Draft* — not planned:
the extension is for Vault Community only (2026-11-03). runbook, after
C.0 question 8, for moving `<tenant>/kv` into Vault namespace `<tenant>`
without changing a workload.

---

## Developer experience — enforcing the method

The method (`method.md`) is enforced by `make verify` and the PR workflow. These
stories close the gaps it lists under "Known enforcement gaps".

**Story DX.1 — CI is a merge gate** 📝 *Draft*

As a reviewer, I want a red `verify` check to block the merge, so that the
method can't be skipped by merging past a failing check.

Done: `verify` listed in `required_status_checks_jobs` for this repo in
`stakater/stakater-github-config`; a PR with a failing check can't be merged.

**Story DX.2 — The method on every edit** 👍 *Approved*

As an engineer or agent, I want `make verify` to run after every edit, so that
a broken rule shows up while I work rather than at the PR, as in kube-ward.

Done: a Claude Code PostToolUse hook in `.claude/settings.json` runs the fast
checks (`make method links`) after each edit to a Markdown file; the hook is
documented in `CLAUDE.md`.

---

## Not on the roadmap (non-goals)

Emulating Vault namespaces · tenant-managed policies or mounts · per-tenant
quotas beyond Community Edition's · provisioning Vault. See `vision.md`.
