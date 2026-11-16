# C.2 — Workload access with the scope check

Story: `docs/roadmap.md` C.2 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-ISO-1, AC-ISO-2, AC-ISO-3, AC-ISO-4, AC-ISO-5, AC-ISO-10,
AC-ACC-1, AC-ACC-2, AC-ACC-3, AC-ACC-4.

## Why (one paragraph)

C.1 gives every tenant a KV mount, but nothing can log in to it. An
application team needs one ServiceAccount annotation to give its app its own
secrets and nothing else. This is the walking skeleton's core: the tenant's
auth mount, one policy and one role per annotated ServiceAccount, the
`vault-config-<sa>` ConfigMap, and the scope check that stands in for the
namespace wall Community Edition does not have. It is also the first story
proven live, so it brings the lab and the e2e suite.

## Governing constraints

- ADR-0007 (supersedes ADR-0002, decided during this story): the tenant's auth
  mount is `auth/<tenant>/kubernetes/workloads`; share roles live on it too, so
  the parent renders no shared auth mount.
- ADR-0003: one policy and role per ServiceAccount; every rendered policy and
  role passes the scope check, which fails the render.
- ADR-0001 and invariant 7: names, annotation keys and ConfigMap keys are the
  Enterprise ones (`vault.stakater.com/kv`, `role`, `app`;
  `kv.<tenant>.<ns>.<sa>`; `VAULT_*`). `VAULT_NAMESPACE` is empty.
- Invariant 3: no `targetNamespace`.
- P1, P2: the policy is the wall; the tenant segment closes with `/` before
  any wildcard.
- A1, Q13, V10: a role binds its ServiceAccount and its namespace by
  `kubernetes.io/metadata.name` and the tenant label, through
  `targetNamespaceSelector`; VCO resolves it to names.
- Enterprise CLAUDE.md e2e rules: assert as the workload; a denial is a 403
  paired with a matching allow.

## Design

Tenant chart `charts/mto-extension-vault-community/`:

- `templates/_helpers.tpl` gains Enterprise's `vault.assertName`,
  `vault.roleName`, `vault.saAnnotationKeys` (`kv`, `role`, `app`),
  `vault.saFacts`, `vault.appClaims`, `vault.errorConfigMap`,
  `vault.tenantNamespaces`, `vault.tokenSeconds`, `vault.tokenType`,
  `vault.roleTokenFields`; `vault.vcoAuth` without namespace or target;
  `vault.k8sAuthMount` = `<tenant>/<path>/<name>`; and the new
  `vault.assertPolicyScope`, which fails the render when a policy line is not
  a one-line stanza, grants `sudo`, or names a path outside
  `<tenant>/kv/{data,metadata,delete,undelete,destroy}/<env>/`, or has a `+`
  or a `*` that is not the last character after a `/`.
- `templates/01-tenant-scaffolding.yaml`: `AuthEngineMount <tenant>-kubernetes`
  (`path: <tenant>/kubernetes`, `name: workloads`) and its
  `KubernetesAuthEngineConfig`.
- `templates/04-sa-own-tenant.yaml`: per annotated ServiceAccount, Policy and
  `KubernetesAuthEngineRole` `kv.<tenant>.<ns>.<sa>`, the ConfigMap
  `vault-config-<sa>`, the `vault-apps` index, the CA bundle ConfigMap. The
  policy grants `<tenant>/kv/{data,metadata}/<env>/<ns>/<app>/*` at the role's
  capabilities, plus `delete`, `undelete`, `destroy` for `admin`. The role:

  ```yaml
  path: team-a/kubernetes/workloads
  targetServiceAccounts: [web]
  targetNamespaces:
    targetNamespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: team-a-api, stakater.com/tenant: team-a }
  policies: [kv.team-a.team-a-api.web]
  ```

  The `_shared` grants and the share annotations come in C.7 and C.8.
- `templates/00-guards.yaml`: calls the component and label guards, so a
  tenant with nothing annotated still fails on a bad value.

Bootstrap: the parent no longer renders `shared-kubernetes` or its config
(ADR-0007); its Template loses the four parameters only they used.

Lab and e2e: `Makefile` lab targets ported from Enterprise for Community only
(kind, cert-manager, Tenant CRD, Template Operator v2 built from local `main`,
ESO, Vault CE 2.1.1, VCO v1.0.3, the in-cluster chart repo, the bootstrap).
`hack/lab/vault-bootstrap.sh` gives VCO its login with the broad lab policy
(the production one arrives in C.3). `tests/e2e/` is the Enterprise suite's
frame (`TestMain`, helpers, `vault.go` without namespaces) with the steps of
this story. `.github/workflows/e2e.yaml` runs it on request.

## Tests (red first)

Render, written before the templates:

- `golden` over `hack/render-fixtures/values-full.yaml`; `disjoint`, `union`,
  `exclusivity`, `empty`, `badvalue`, `namebudget`, `nullfields` (tenant
  half), `namecollide`, `tenantname` (tenant half), `tokenseconds`,
  `tokentype`, `toggles` (tenant half), ported.
- `policyscope`: every Policy of every fixture passes the scope check, read
  from the output; a policy built with a hostile path fails the render
  (AC-ISO-3, AC-ISO-4).
- `rolebind`: every role binds its own policy, its tenant's mount, its own
  ServiceAccount and a selector of exactly the namespace name and tenant label
  (AC-ISO-5, AC-ISO-10).
- `mountagree`: the auth mount path agrees across the mount, its config, every
  role and `VAULT_K8S_MOUNT`; `VAULT_NAMESPACE` is empty.
- `guards`: the Enterprise fixture's ServiceAccount cases that apply.
- `crd-validate` over every fixture and slice, exact counts.

Mutation tests: widen a path, drop the tenant label from the selector, and
remove the `/` after the tenant; each named check goes red.

Live (`make e2e-kind`): preflight refuses Vault Enterprise; install; the
tenant mounts and auth mounts appear; a workload logs in at its tenant's mount
and reads and writes its own prefix; a sibling app, another tenant's mount and
another tenant's role are refused with a 403 paired with an allow; a
namespace of the same name with another tenant's label gets no login
(AC-ISO-10); viewer, editor, admin and audit-read capabilities.

## Out of scope

`_shared` (C.7), shares (C.8), the eso slice (C.4), SSO (C.6), VCO's
production policy and the admission policies (C.3), the contract check (C.5),
lifecycle steps (C.9).

## Done means

The roadmap Done line; `make verify` green; mutation tests run; golden
committed; both chart versions stay 0.1.0 (unreleased); `make e2e-kind` green
on the lab with output seen; `charts/README.md` "Workload access" written;
story marked ✅ with this doc linked.
