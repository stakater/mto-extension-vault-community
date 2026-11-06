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

**Story C.9 — Lifecycle that keeps data** ✅ *Done*

As a platform team, I want offboarding to revoke access at once and keep the
data, so that a mistaken delete never loses secrets.

Done: live under the production VCO policy: last namespace unlabelled (grants
gone, data kept); annotation removed (policy and role gone); tenant deleted
(its auth mounts disabled, tokens revoked, `<tenant>/kv` kept); tenant
recreated (it adopts the retained data, visible); the admin purge order
documented in `charts/README.md`. Satisfies **AC-LIFE-2..5**, **AC-ACC-5**.
Planning: [`planning/C9-lifecycle-keeps-data.md`](planning/C9-lifecycle-keeps-data.md).

**Story C.10 — Rotation reaches the pod** ✅ *Done*

As an application team, I want a new secret version to reach my pod without a
manual restart, so that rotation is routine.

Done: the Reloader annotation documented; live: a new version written in Vault
reaches a new pod through ESO and Reloader. Satisfies **AC-DEL-2**. Planning:
[`planning/C10-rotation-reaches-the-pod.md`](planning/C10-rotation-reaches-the-pod.md).

**Story C.11 — Health and preflight** ✅ *Done*

As a platform team, I want each tenant's Vault state and errors visible on the
Kubernetes side, so that a failure is found without reading Vault.

Done: the Template outputs and the optional PrometheusRule ported; a mount
collision surfaces on its own tenant only; the e2e preflight refuses Vault
Enterprise. Satisfies **AC-OPS-1**, **AC-OPS-2**. Planning:
[`planning/C11-health-and-preflight.md`](planning/C11-health-and-preflight.md).

**Story C.17 — The review of Phases 1 and 2, closed** ✅ *Done*

As a security owner, I want every finding of the adversarial review of Phases
1 and 2 fixed and pinned by a test, so that the docs' promise "the admission
policies hold for every writer of `vault-config`" is true and stays true.

Approved by Ayesha Arshad on 2026-11-04 ("fix" on the review).

Done: admission refuses every VCO kind the extension does not render, any
`spec.connection`, and any `spec.authentication` but the install's; the origin
check holds with a wrong `templateOperator.*`; the admission CEL runs offline
in `make verify` against the cases of `hack/lab/admission-cases.sh`; the
content checks read the `core` and `eso` renders; every fail branch of the
render-time scope check has a bad input; `hack/mutation_tests.py` kills every
listed guard mutation; install-wide values are validated at install; the
tenant-name budget, group patterns, quoting, token zero, release and
bump-check defects fixed; AC-ISO-10 proven with the role still in Vault; the
docs match the code. Satisfies **AC-ISO-6**, **AC-ISO-7**, **AC-ISO-10**,
**AC-ISO-11**, **AC-ISO-12**, **AC-OPS-1**. Planning:
[`planning/C17-review-closed.md`](planning/C17-review-closed.md).

**Story C.18 — The second review, closed** ✅ *Done*

As a security owner, I want the findings of the review of C.17 fixed and
pinned, so that no CR gets a new spec past admission while it is deleted, and
the tests that guard the wall fail for the reason they name.

Approved by Ayesha Arshad on 2026-11-04 ("Fix" on the second review).

Done: a spec changed during a deletion is checked even when one side has no
spec, and a VCO CR without a spec is refused; every refusal case names the
policy that must give it, and UPDATE cases reach the kinds and origin
policies; the offline runner checks every expression compiles for Kubernetes
1.30 and runs an exact number of cases; each mutation names the check that
must kill it; install values that would break every tenant fail the install;
the docs say what is true. Satisfies **AC-ISO-6**, **AC-ISO-11**,
**AC-ISO-12**. Planning:
[`planning/C18-second-review-closed.md`](planning/C18-second-review-closed.md).

**Story C.20 — The third review, closed** ✅ *Done*

As a security owner, I want the findings of the review of C.18 fixed and
pinned, so that no install value that passes the install breaks every tenant,
and each guard's test fails only for that guard.

Approved by Ayesha Arshad on 2026-11-05 (the third review's 8 findings, and
"make the code true" for the deletion of a CR without a spec).

Done: a one-sided `parent.token` value is checked against the tenant chart's
default for the other side; a mount name with a trailing `/` renders as the
admission policies expect; a group pattern with a control character, and two
auth mounts on one path, fail the install; the schema types every
`tenantValues` value the tenant chart reads; `schemakeys` pins the exact list
of closed objects; a mutation is killed only by its own case, never by a
crash or another guard, and a mutation text that matches more than once
fails the run; the live admission run sends the deletion attack's first step
and the update cases to a real API server, and the e2e pins the split of live
and offline cases; a deletion is not blocked, also for a CR without a spec
(C.21 names the one exception);
the docs say what is true. Satisfies **AC-ISO-6**, **AC-ISO-11**,
**AC-ISO-12**. Planning:
[`planning/C20-third-review-closed.md`](planning/C20-third-review-closed.md).

**Story C.21 — The fourth review, closed** ✅ *Done*

As a security owner, I want the findings of the review of C.20 fixed and
pinned, so that no install value turns the admission policies off or breaks
every tenant, and each admission rule's test fails only for that rule.

Approved by Ayesha Arshad on 2026-11-05 ("fix these" on the fourth review).

Done: a null toggle takes the chart default; each admission refusal case
names the rule that must refuse it, and every rule of the four policies that
the review found unpinned has a case that only it refuses; the charts' own
render passes the admission CEL in `make verify`; every string that comes
from a value renders as a string; a `tenantValues.ssoToken` TTL set on one
side is checked against the other; the mutation runner counts no crash as a
kill, tests its own evaluator, and lists every new guard; the docs say what is
true. Satisfies **AC-ISO-6**, **AC-ISO-11**, **AC-ISO-12**. Planning:
[`planning/C21-fourth-review-closed.md`](planning/C21-fourth-review-closed.md).

**Story C.19 — The C.17 and C.18 fixes in the Enterprise extension** 📝 *Draft*
— in `stakater/mto-extension-vault-enterprise`, which has the same gaps: a
group pattern without `{tenant}` binds one group in every tenant, role
patterns can give two tenants one group, ServiceAccount and namespace names
render unquoted, and a workload role binds its namespace by name only, not by
name and tenant label (Q13, `design.md` §2). Seen in its charts at f7a4155,
the C.21 gaps too: a null toggle reads as off (`boolValue`, `esoMode`),
`vco.role`, `kubernetesHost`, the client secret key, the refresh interval and
a slice key render unquoted, and `ssoToken.ttl` is not compared with
`maxTTL`. Contract parity (ADR-0001) holds without it: none of these is a
contract change.

**Story C.22 — Admission after a reinstall** 👍 *Approved*

As a platform engineer, I want the admission policies to keep working after
an uninstall, or after `admission.enabled` goes off and on again, so that a
reinstall does not stop every tenant's login until kube-apiserver restarts.

Found in the smoke run of 2026-11-06 on kind (Kubernetes v1.33.4). The
`vco-cluster` policy reads `kube-root-ca.crt` in `configNamespace` as its
parameter, a built-in `paramKind`. When the last policy with that
`paramKind` goes, kube-apiserver stops the informer for it, and a new policy
uses the stopped informer
([kubernetes/kubernetes#141015](https://github.com/kubernetes/kubernetes/pull/141015)).
A ConfigMap made after that point is not found: every
`KubernetesAuthEngineConfig` is refused with "no params found", and no tenant
gets a working login until kube-apiserver restarts. A config namespace made
before the deletion still works. The refusal is fail-closed. The e2e suite
does not see it, because it installs once.

Approved by Ayesha Arshad on 2026-11-06; the option is not chosen yet.

A decision is necessary. The options:

1. Keep the ConfigMap parameter. Document the fault, how to see it (the
   TemplateInstance's `Applied` condition says "no params found"), the
   recovery (restart kube-apiserver), and the Kubernetes releases that have
   the fix.
1. A parameter of a CRD kind. The upstream report says that CRD kinds do not
   have the fault; not tested here. It adds a CRD and an install order.
1. No parameter: the CA in the CEL at render. A render without cluster
   access (`helm template`, GitOps) then fails.

Done: the decision is recorded (an ADR if it changes the design); on kind,
the reproduction passes: delete and create the policy, make a new config
namespace, install, and a workload logs in. Satisfies **AC-ISO-11**.

**Story C.23 — VCO's policy for other mount paths** ✅ *Done*

As a Vault admin, I want to know which paths of VCO's policy change when I
set `kubernetesAuth.path`, `kubernetesAuth.name` or `tenantValues.sso.mount`,
so that VCO can write the tenant mounts at the paths I chose.

Approved by Ayesha Arshad on 2026-11-06.

Found in the smoke run of 2026-11-06. `charts/examples/vco-admin-policy.hcl`
and the lab policy name only `+/kubernetes/workloads` and `+/oidc/sso`. With
the workload mount at `k8s/apps`, Vault answers `deny` to that policy on
`sys/auth/<tenant>/k8s/apps` and on the roles under it, so every tenant's auth
mount fails. `charts/README.md` lists the values as settings, but does not say
that the policy must change. With the policy changed by hand, the e2e suite
passes on those values (32 steps; the admission cases are skipped, because
they are written for the defaults).

Done: `charts/README.md`, at the values and at the policy, names the paths to
change, or the bootstrap chart renders the policy for the install's paths; a
render test fails when the example policy does not cover a rendered mount
path. Satisfies **AC-ISO-7**. Planning:
[`planning/C23-vco-policy-mount-paths.md`](planning/C23-vco-policy-mount-paths.md).

**Story C.24 — A null value on `--reuse-values`** ✅ *Done*

As a platform engineer, I want the docs to say that a null value on
`helm upgrade --reuse-values` does not reset a value to its default, so that
I do not leave ESO or the admission policies off when I mean the default.

Approved by Ayesha Arshad on 2026-11-06.

Found in the smoke run of 2026-11-06 with Helm 3.14.0. After
`--set parent.eso=disabled`, `helm upgrade --reuse-values --set
parent.eso=null` stores `eso: null`, but Helm computes `disabled` from the old
value, and the chart never gets the null. Without `--reuse-values`, a values
file with `eso: null` gives the default, as C.21 made it. The same Helm
behaviour applies to `admission.enabled`; not tested.

Done: `charts/README.md` says it next to "Null is the default", with the two
upgrades that reset a value: an explicit value, or all values again without
`--reuse-values`. Satisfies **AC-ISO-11**. Planning:
[`planning/C24-null-reuse-values.md`](planning/C24-null-reuse-values.md).

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
Kind E2E is made required only where a run it skipped can't count as a pass
(checked on a test PR), or it stays out of the list.

**Story DX.2 — The method on every edit** ✅ *Done*

As an engineer or agent, I want `make verify` to run after every edit, so that
a broken rule shows up while I work rather than at the PR, as in kube-ward.

Done: a Claude Code PostToolUse hook in `.claude/settings.json` runs the fast
checks (`make method links`) after each edit to a Markdown file; the hook is
documented in `CLAUDE.md`. Planning:
[`planning/DX2-method-on-every-edit.md`](planning/DX2-method-on-every-edit.md).

**Story DX.3 — The lab's Dex check survives a restart** ✅ *Done*

As an engineer, I want `make e2e-kind` to pass on a new lab, so that a red
Kind E2E run means a defect, not a race in the lab.

Approved by Ayesha Arshad on 2026-11-06.

Found in the smoke run of 2026-11-06. `lab-dex` restarts Dex and then runs
one `wget` from the Vault pod, with no timeout and no retry. The connection
went to the old pod's address and hung for the kernel's connect timeout
(about 127 s), and the lab build failed. Dex answered when it was probed
again. CI runs `make e2e-kind`, so its run can fail the same way.

Done: the check tries again with a short timeout on each try, for a fixed
time, and still fails with the same message when Dex never answers; the lab
builds from zero. Planning:
[`planning/DX3-lab-dex-check.md`](planning/DX3-lab-dex-check.md).

**Story DX.4 — CI is green on Linux** ✅ *Done*

As a reviewer, I want the PR's Verify and Kind E2E checks to pass in CI, so
that a green local run means a green CI run.

Approved by Ayesha Arshad on 2026-11-06 ("yes").

Found on 2026-11-06. CI Verify failed from b59afe7 to 7521bb9: CI runs the
pinned Helm v3.19.0, which writes schema errors in another form than Helm
3.14, and six render checks matched the 3.14 text. The first Kind E2E run in
CI failed in `lab-dex`: GNU make 4 keeps a backslash-newline inside single
quotes, so jq got `\` in the Dex config program; macOS make 3.81 removes it.

Done: the render checks accept the schema errors of Helm 3.14 and of the
pinned Helm, and `make verify` passes with both; the Dex config program is a
jq file, and a test fails on a recipe line continued inside single quotes;
`lab-dex` writes the same config under GNU make 4 and make 3.81; CI Verify and
Kind E2E pass on the PR. Planning:
[`planning/DX4-ci-green-on-linux.md`](planning/DX4-ci-green-on-linux.md).

---

## Not on the roadmap (non-goals)

Emulating Vault namespaces · tenant-managed policies or mounts · per-tenant
quotas beyond Community Edition's · provisioning Vault. See `vision.md`.
