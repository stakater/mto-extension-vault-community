# C.20 — The third review, closed

Story: `docs/roadmap.md` C.20 (👍 Approved by Ayesha Arshad, 2026-11-05).
Acceptance: AC-ISO-6, AC-ISO-11, AC-ISO-12.

## Why (one paragraph)

A third adversarial review, of C.18, found 8 important issues. A one-sided
`parent.token.ttl` or `maxTTL` installs and then fails every tenant, because
the install compares the two only when both are set (a regression of C.18:
before it, Vault capped the value). A trailing `/` on `kubernetesAuth.name`
or `sso.mount.name` passes the install check, which trims it, but the tenant
chart renders it, and admission refuses every tenant's mount; a newline in a
group pattern does the same to the SSO roles. Two auth mounts can be put on
one path. Wrong-typed `tenantValues` install and fail every tenant, and
misspelt keys in `clientSecretRef` and `ssoToken` are ignored. `schemakeys`
stays green when a closed schema object is opened by a type change. The
mutation suite can count a crash or another guard's message as a kill, and a
mutation text that matches more than once is not reported. CI never sends the
deletion attack to a real API server, and the e2e does not pin how many cases
run live. Some docs are wrong, and "a deletion is never blocked" is not true
for a CR without a spec.

## Governing constraints

- Invariant 5 and ADR-0008: every VCO CR in `vault-config` passes admission;
  a deletion is the one exemption, and only a change that cannot reach VCO
  may use it. A deletion is never blocked.
- Invariant 1 and ADR-0003: each copy of the scope check fails on its own bad
  input; the tenant chart renders what the admission policies expect.
- Invariant 7 and ADR-0001: nothing here changes the contract (annotations,
  roles, names, ConfigMap keys). The Enterprise repo's gaps are story C.19.
- The method, "Every guard mutation-tested": a mutation is killed only by the
  check it names, through the guard's own case.

## Design

Bootstrap install checks (`charts/mto-extension-vault-community-bootstrap/templates/_helpers.tpl`):

- `parent.token`: a side that is not set takes the tenant chart's default
  (`defaultToken`: `ttl` 3600, `maxTTL` 14400, pinned to the tenant chart's
  `values.yaml` by `tenantvaluekeys`); 0 means Vault's default and is not
  compared.
- The Kubernetes auth mount `kubernetesAuth.path/name` and the SSO mount
  `tenantValues.sso.mount.path/name` (default `oidc/sso`) are not one path,
  and neither is inside the other.
- A group pattern holds no control character (a newline folds to a space in
  the admission policies' YAML, so the CEL expects another group).
- `ssoCollision`: the "same tenant" results are their own conditions, not a
  label on the "two tenants" result, so each is a guard; the pair loop skips
  two entries of one role (the "listed twice" guard refuses those).

Bootstrap schema (`values.schema.json`): `tenantValues.roleCaps` is a map of
strings, `tenantRoleMapping` a map whose entries are a map or a string with a
string `pattern`, `ssoToken` and `sso.oidc.clientSecretRef` closed maps of
strings, `vaultCABundle`, `caBundlePem`, `clientId`, `tenantGroupTemplate`,
`sso.mount.*` and `monitoring.prometheusNamespace` strings.

Tenant chart: the `name` of the Kubernetes and OIDC `AuthEngineMount` and of
the Kubernetes auth config is trimmed of `/`, as `path` already is
(`templates/01-tenant-scaffolding.yaml`, `templates/06-oidc-auth.yaml`).

Admission (`templates/50-admission.yaml`): the deletion exemption also covers
an update where neither side has a spec. Neither side can carry a
`spec.connection`, so the C.18 attack (spec removed, then put back with a
connection) stays refused at each step.

Tests and tools:

- `hack/mutation_tests.py`: a `count=1` mutation must match exactly once;
  a FAIL line with "failed elsewhere" or a template crash is a kill only when
  it holds the mutation's `detail` (its own case); `quote-ns`,
  `cel-kinds-delete` and `dns-regex-respelt` anchored on one match; the six
  mutations killed by another guard's message get a case only their guard
  refuses. A unit test (`hack/test_mutation_tests.py`) pins both rules.
- `hack/chart-render-tests.sh`: the bootstrap and the parent render at setup,
  so a parse error stops the run before any check.
- `hack/lab/admission-cases.sh`: in live mode an update case creates its old
  object for real, holds it in deletion with a finalizer when the case needs
  that, and sends the update as a server-side dry run; only the cases whose
  old object admission refuses (a spec out of scope, no spec) stay offline.
- `tests/e2e/scenarios_test.go`: the admission step pins the result line:
  the number of cases, 0 failed, the number offline only.

## Tests (red first)

- `installvalues`: `parent.token` with `ttl: 20000` only, and with
  `maxTTL: 1800` only, fail; `kubernetesAuth: {path: oidc, name: sso}`, a
  mount inside the other, and an SSO mount on the Kubernetes path fail; the
  wrong-typed `tenantValues` fail through the schema; near misses render.
- `mountagree`: a render with `/` around every mount path and name agrees on
  `team-a/kubernetes/workloads` and `team-a/oidc/sso`.
- `ssogroups`: a newline in a pattern; one-role cases for a pattern without
  `{tenant}`; a role named `fallback` with caps.
- `scopebranches`: a bare in-scope path line is not a stanza.
- `schemakeys`: the exact list of closed objects; `tenantvaluekeys`: the
  token defaults.
- `make admission-offline`: a finalizer removed during a deletion of a CR
  without a spec is admitted; a finalizer removed during a deletion of an
  object in scope is admitted.
- `make test`: the runner's ambiguity and crash rules.
- `make mutation-test`: every new guard's mutation, killed by its named check.

## Out of scope

The Enterprise repo (C.19). The second step of the C.18 attack live: its old
object (a deleting CR without a spec) cannot exist while admission is on, so
it runs offline only. An audience on `vco-admin` (C.17).

## Result (2026-11-05)

- `make verify` green; the golden unchanged.
- `make admission-offline`: 77 cases, 0 failed.
- `make mutation-test`: 109 mutations, 109 killed by their named check. The
  six that C.18 counted on another guard's message are now killed by their
  own case.
- `make admission-test` on the kind lab (Kubernetes 1.33): 77 cases, 0
  failed, 3 offline only (74 run live). Live, a Policy held in deletion by a
  finalizer: the update that removes its spec is refused by `vco-kinds`, and
  the finalizer removal passes.
- `make e2e-test` on the lab: 33 of 33 steps pass; the admission step pins
  the split, 74 live and 3 offline only.
- Seen on the lab, not fixed here: `make admission-test` run at once after a
  fresh `make lab-bootstrap` admitted its first case, before the API server
  had loaded the new policies; the next run was green. It can only give a
  false failure, never a false pass.

## Done means

The roadmap Done line; `make verify`, `make mutation-test`,
`make admission-test` on the lab green with output seen; docs corrected
(`design.md`, `charts/README.md`, `diagrams.md`, `acceptance.md`,
`method.md` where it applies, the C.17 and C.18 planning docs); story marked
✅ with this doc linked.
