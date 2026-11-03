# Acceptance scenarios

The isolation contract, as testable scenarios. Stories cite these by id. Each
scenario names its **level**: **R** = render test (no cluster), **L** = live
(kind lab with Vault Community 2.1.1 and VCO v1.0.3), **R+L** = both.

The Enterprise extension's e2e rules apply unchanged: assert in Vault **as the
workload** (its own ServiceAccount token); a denial counts only as a 403 and
needs a matching allow on the same path; a denial must test a capability the
caller would have if the guard broke; mutation-test every new denial.

Fixture: tenants `team-a` (namespaces `team-a-api`, `team-a-worker`), `team-b`
(`team-b-api`) and `team` (`team-core`), whose name is a prefix of `team-a`'s.
ServiceAccounts `web` (team-a-api, editor), `jobs` (team-a-api, viewer),
`worker` (team-a-worker, viewer, subscribes to team-a-api), `api`
(team-b-api, editor), `core` (team-core, admin). IdP groups `<tenant>-<role>s`;
users `alice` (team-a-editors), `bob` (team-a-viewers), `carol`
(team-b-admins), `dave` (team-a-audit-reads), `erin` (team-a-admins).

## Isolation

**AC-ISO-1 — An app can't read a sibling app.** *(L)* `jobs` is refused
`team-a/kv/data/dev/team-a-api/web/x`; `web` reads it.

**AC-ISO-2 — A tenant can't reach another tenant's mount.** *(L)* `web` is
refused read and list on `team-b/kv/`; `api` reads the same path.

**AC-ISO-3 — A prefix tenant can't reach its longer neighbour.** *(R+L)* No
rendered policy for `team` contains `team*` or any path not starting `team/`;
`core` is refused `team-a/kv/data/...`.

**AC-ISO-4 — Every policy stays in scope.** *(R)* For every fixture, every
`path` in every Policy rendered for tenant `t` satisfies design §4; a fixture
built to violate it fails the render with a message naming the path.

**AC-ISO-5 — Another tenant's login role doesn't work.** *(L)* `web` logging
in with role `kv.team-b.team-b-api.api` on `team-b/kubernetes/workloads` is
refused with 403 `service account name not authorized` (observed in C.0);
`api` logs in with it.

**AC-ISO-6 — A group gives its role in its own tenant only.** *(L)* `alice`
can't log in with `sso.team-b.editor` (claim refused, paired with `carol`
logging in to `sso.team-b.admin`); `alice`'s token is refused `team-b/kv/`.

**AC-ISO-7 — VCO can't widen itself.** *(R+L)* No rendered Policy name falls
outside `kv.`/`share.`/`sso.`; with the production VCO policy, a hand-made
`Policy` CR named `vco-admin` or `default` is refused by Vault and VCO reports
the error; a `KubernetesAuthEngineRole` on `auth/kubernetes` (VCO's own mount)
is refused; a mount of the wrong type is refused (observed in C.0). Names
alone are not enough: a `kv.*` Policy that grants `path "*"` is refused at
admission (AC-ISO-11), because through VCO it would give a token close to
root (C.0 Q16).

**AC-ISO-8 — Names that would break the scope are refused.** *(R)* Tenants
`sys`, `auth`, `identity`, `cubbyhole`, `agent-registry`, `shared`, `secret`,
`Team_A` and a 64-character name get no mount and no child TI; each is listed with its
reason in the skipped-tenants ConfigMap.

**AC-ISO-9 — No role administers Vault.** *(L)* `erin` (admin) is refused
`sys/policy/x`, `sys/mounts/x`, `auth/team-a/kubernetes/workloads/role/x`.

**AC-ISO-10 — A reused namespace name gets nothing.** *(L)* `team-a`'s
namespace `team-a-gone` is deleted and created again with
`stakater.com/tenant: team-b`: its `app` is refused `kv.team-a.team-a-gone.app`
with 403, and VCO has bound the role to `__no_namespace__`. Created again with
`team-a`'s label, `app` logs in (observed in C.0).

**AC-ISO-11 — Out-of-scope VCO CRs are refused at admission.** *(L)* Every
refusal case of `spikes/c0/q18-admission.sh` — a path outside the tenant, a
share in the wrong direction, a role bound to another tenant's policy, mount,
ServiceAccount or label, an SSO role for another tenant's group or with no
claims, a mount or auth config of another shape, cluster or CA — is refused by
the admission policy, each paired with its admitted twin (observed in C.0).

**AC-ISO-12 — Template Operator can't write for a tenant.** *(L)* A Template
and TemplateInstance in `team-a-api` whose object names
`namespace: vault-config` produce no VCO CR there: the origin policy refuses
it (observed in C.0).

## Access roles

Inherited from the Enterprise suite, run on Community Edition:

**AC-ACC-1 — audit-read lists, never reads.** *(L)* `dave`.
**AC-ACC-2 — viewer reads, can't write.** *(L)* `jobs`, `bob`.
**AC-ACC-3 — editor writes, can't delete or destroy.** *(L)* `web`, `alice`.
**AC-ACC-4 — admin deletes, undeletes and destroys versions.** *(L)* `core`, `erin`.
**AC-ACC-5 — A role change rewrites in place.** *(L)* `web` lowered to viewer:
its existing token and a new login both lose write and keep read.
**AC-ACC-6 — Group removal stops new logins.** *(L)* `alice` removed from
`team-a-editors` can't log in at editor.

## Sharing

**AC-SHR-1 — A namespace's shared folder.** *(L)* `web` writes
`team-a/kv/data/dev/_shared/from-team-a-api/`; `jobs` reads it and can't write.
**AC-SHR-2 — Subscription.** *(L)* `worker` reads it, directly and through ESO,
and can't write; a ServiceAccount without the annotation is refused.
**AC-SHR-3 — Across tenants.** *(L)* `web` with `kv-export-tenant: team-b`
writes `shared/kv/data/dev/from-team-a/to-team-b/`; `api` with
`kv-import-tenant: team-a` reads it and can't write; each is refused the
other's share role; each share role logs in at its own tenant's mount,
`VAULT_K8S_MOUNT` (ADR-0007); the prefix tenant `team`'s export can't reach
`from-team-a/` (observed in C.0, 11 checks).

## Delivery

**AC-DEL-1 — An annotation becomes a Secret.** *(L)* `kv-secret.db-creds:
postgres` on `web`'s Deployment gives Secret `web-db-creds`; the pod sees it.
**AC-DEL-2 — Rotation reaches the pod.** *(L)* A new version in Vault reaches
the Secret, and Reloader rolls a pod that sees it.

## Lifecycle

**AC-LIFE-1 — Pick-up rules.** *(R)* Every valid Tenant gets a mount; a tenant
with ≥1 labelled namespace gets child TIs; one with none gets none and the
parent stays healthy.
**AC-LIFE-2 — Last namespace unlabelled keeps data.** *(L)* `team-b`'s grants
go, `team-b/kv/` and its secrets stay; labelling a namespace again restores
the grants.
**AC-LIFE-3 — Annotation removed revokes.** *(L)* Policy, role and ConfigMap
gone; the login is refused.
**AC-LIFE-4 — Tenant deleted keeps data.** *(L)* With the production VCO
policy: grants and `team-a`'s share roles go; `team-a`'s auth mounts are
disabled and a workload token issued before is refused with 403; the mount CR
stays `Terminating`; the secret is still in Vault; the documented admin
procedure finishes it.
**AC-LIFE-5 — Name reuse is visible.** *(L)* A new `team-b` adopts the retained
mount and its secrets; the docs say so and give the purge steps.

## Parity and operations

**AC-PAR-1 — Same contract as Enterprise.** *(R)* Annotation keys, role names,
name families and ConfigMap key names equal the pinned Enterprise chart's;
only `VAULT_NAMESPACE` and the mount prefix in paths differ. Checked by the
render test `contract` (`hack/contract.sh` against
`hack/enterprise-contract.txt`; any difference must be listed in
`hack/contract-delta.txt` with the story that removes it).
**AC-OPS-1 — VCO errors surface per tenant.** *(L)* A broken role shows in
`kubernetesAuthEngineRoleLastError` on the child TI (the mechanism observed in
C.0, with `secretEngineMountLastError` and `policyLastError`).
**AC-OPS-2 — A mount collision surfaces, alone.** *(L)* A tenant named like an
unlisted platform mount reports the error; other tenants are unaffected.
