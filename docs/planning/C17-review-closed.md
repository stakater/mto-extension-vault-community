# C.17 — The review of Phases 1 and 2, closed

Story: `docs/roadmap.md` C.17 (👍 Approved by Ayesha Arshad, 2026-11-04).
Acceptance: AC-ISO-6, AC-ISO-7, AC-ISO-10, AC-ISO-11, AC-ISO-12, AC-OPS-1.

## Why (one paragraph)

An adversarial `/code-review` of `feat/community-charts` (C.0 to C.11, DX.2)
found two critical defects. First, the admission policies did not hold for "a
person", as `README.md`, design §4 and ADR-0008 say: the scope policy matched 6
of VCO's ~80 kinds and read no `spec.connection`, so a `Policy` CR in scope
with `spec.connection.address` set to another host made VCO send its
`vco-admin` login JWT there, and an `AppRoleAuthEngineRole` wrote
`auth/<path>/role/<name>` unchecked. Second, the tests stayed green when
guards were weakened: 6 of 15 guard mutations survived, because the admission
CEL never ran in `make verify`, the content checks read only the
`component=all` render, four fail branches of `vault.assertPolicyScope` had no
bad input, and `vcopolicy` missed `sys/policies/acl/*` and `+` forms. Thirteen
important findings and ten suggestions came with them. The method turns
review findings into a story; this is it.

## Governing constraints

- Invariant 1 and ADR-0003: the scope check runs at render, in the harness and
  at admission; each copy must fail on its own bad input.
- Invariant 5 and ADR-0008: VCO's token is root-equivalent, so every VCO CR in
  `vault-config` must pass admission. The admission is the wall: it must
  cover every kind and every field that changes where or as whom VCO writes.
- Invariant 7 and ADR-0001: no change to annotations, roles, names or
  ConfigMap keys. Refusing a group pattern without `{tenant}`, quoting names and
  stricter validation change no contract line; the Enterprise chart has the
  same gaps (named in "Out of scope").
- ADRs are immutable: ADR-0008's text becomes true; no ADR changes.
- `docs/vault-community-baseline.md` V13: VCO's login role binds `vault-config`
  only. VCO v1.0.3 requests its token with no audience
  (`api/v1alpha1/utils/commons.go:287`), so the token carries the API server's
  audience.

## Design

Admission (`charts/mto-extension-vault-community-bootstrap/templates/50-admission.yaml`):

- New policy `mto-extension-vault-community-vco-kinds`, on every namespaced
  `redhatcop.redhat.io` resource in `configNamespace`: the kind is one of the
  seven the extension renders; no `spec.connection`; `spec.authentication` is
  exactly `vco.authPath`, `vco.role`, `vco.serviceAccount`, with no
  `namespace` or `targetNamespace`.
- `origin`: for every writer, an object that carries Template Operator's
  `instance-namespace` label must carry `configNamespace` there (Template
  Operator stamps it on every object it writes,
  `internal/controller/templateinstance_controller.go:233`); for Template
  Operator's own ServiceAccount the label is also required. A wrong
  `templateOperator.*` then no longer disables the check. `scope: Namespaced`.
- `scope`: a Policy has no `spec.type`.
- Every policy: the deletion exemption only when the spec is unchanged.

Install-wide values (bootstrap `_helpers.tpl`, `values.schema.json`, new
`templates/01-checks.yaml`): `templateOperator.*` and `parent.sharedTenantName`
are validated names; every SSO role is a DNS label and every group pattern has
`{tenant}` exactly once and no quote or backslash; no two roles' patterns can
give two tenants the same group; `parent.token` keeps a `0`; the schema refuses
unknown keys at every level it knows, and `tenantValues` keys (top level,
`sso`, `sso.oidc`, `sso.mount`, `monitoring`) are pinned to the tenant chart's
`values.yaml`.

Parent (`files/parent-gotemplate.tpl`): a tenant name over 29 characters is
skipped and listed (`mto-extension-vault-community-<tenant>.eso` caps at 63).

Tenant chart: `vault.assertPolicyScope` counts the parts per family and
quotes the shared and peer names into its regexes; `vault.ssoGroup` refuses a
pattern without `{tenant}`; every ServiceAccount and namespace name is quoted.

Tests and tools: `hack/admission-eval` (Go, k8s.io/apiserver's own
ValidatingAdmissionPolicy plugin) runs the rendered policies offline against
the cases `hack/lab/admission-cases.sh` emits with `EMIT=<dir>`
(`make admission-offline`, part of `make charts`); the harness checks content
equality of `core` ∪ `eso` against `all` for every fixture, a probe chart
gives each `vault.assertPolicyScope` branch a bad input, `vcopolicy` pins the
exact path set; `hack/mutation_tests.py` (`make mutation-test`, run in CI)
applies each guard mutation to a copy of the repo and expects a check to fail.
`release-chart.sh` fails when a published version's content differs;
`version-bump-check.sh` normalises a trailing slash; `crd-validate` counts
exactly; `check_method.py adr-diff` uses `--no-renames`; the post-edit hook
ignores files outside the repo; the lab targets refuse a context that is not
`kind-*`; `make admission-test` passes the issuer and the script refuses to
run without one; the e2e workflow tests the event's SHA; `github.base_ref`
goes through `env:`.

E2E: AC-ISO-10 keeps e2e-alpha's role in Vault (the suite writes the same
role spec as its own CR) and asserts a 403, the role's `__no_namespace__`
binding and the paired allow after relabelling; the helpers no longer read any
error as "gone".

Not changing: the contract, the rendered objects' content (the golden stays),
the ADRs.

## Tests (red first)

- `make admission-offline` with the new cases (another kind, a
  `spec.connection`, another `spec.authentication`, Template Operator's
  label from a tenant namespace with any writer, a spec change during
  deletion) before the policy changes: red.
- Harness: `union` content equality, `policyscope` on the slices, `scopebranches`
  (one bad input per fail branch), `vcopolicy` exact paths, `quoting` (SA
  `true`, namespace `123`), `ssogroups`, `installvalues`, `reserved` with a
  30-character name, `parentplumb` with `ttl: 0`, `release` with different
  content, `bumpcheck` with `charts/a/`, `dnsregex`, `tenantvaluekeys`.
- `hack/test_check_method.py`: a renamed and edited Accepted ADR fails.
- `hack/test_post_edit_hook.py`: a Markdown file outside the repo runs nothing.
- `hack/mutation_tests.py`: every mutation killed.
- Live: `make admission-test` on the lab; `make e2e-kind` when the lab allows.

## Out of scope

- The same fixes in `mto-extension-vault-enterprise` (group pattern without
  `{tenant}`, unquoted names): story C.19.
- An audience on VCO's `vco-admin` role: VCO v1.0.3 sends a token with the API
  server's audience, so an audience binding can't stop the replay of a token
  VCO sent elsewhere; refusing `spec.connection` does.
- Making Kind E2E a required check (DX.1).

## Result (2026-11-04)

- `make verify` green; the golden unchanged.
- `make admission-offline`: 59 cases, 0 failed. Against the old
  `50-admission.yaml` the same cases fail 10 times (every new case: another
  kind, `spec.connection`, another `spec.authentication`, a policy type, the
  origin label from another writer, a spec widened during a deletion).
- `make mutation-test`: 46 mutations, 46 killed.
- `make admission-test` on the kind lab (Kubernetes 1.33): 59 cases, 0
  failed, of which 2 offline only (57 run live).
- `make e2e-test` on the lab: 33 of 33 steps pass, AC-ISO-10 among them.

## Done means

The roadmap Done line; `make verify` and `make mutation-test` green with output
seen; golden unchanged; design, acceptance, concepts, README and
`charts/README.md` updated; story marked ✅ with this doc linked.
