# C.18 — The second review, closed

Story: `docs/roadmap.md` C.18 (👍 Approved by Ayesha Arshad, 2026-11-04).
Acceptance: AC-ISO-6, AC-ISO-11, AC-ISO-12.

## Why (one paragraph)

A second adversarial review, of C.17, found one critical bypass: the
admission's deletion exemption skipped the request when one side had no
spec, so a Policy held in deletion by a finalizer could be updated to no spec
and then to a `spec.connection` past all four policies, and VCO would log in
at that address before its deletion branch ran. It also found that no test
sent an UPDATE through the kinds or origin policies, that the offline runner's
compile check never fired and a refusal case passed on a denial from any
policy, that a mutation counted as killed on any non-zero exit, that 11 of 14
new mutations survived, that several install values still break every
tenant's render after a green install, and that some docs claim more than is
true. C.17 also promised an Enterprise story that did not exist.

## Governing constraints

- Invariant 5 and ADR-0008: every VCO CR in `vault-config` passes admission;
  a deletion is the one exemption, and only a finalizer change may use it.
- Invariant 1 and ADR-0003: each copy of the scope check fails on its own bad
  input; a test that passes on another check's failure is not that test.
- Invariant 7 and ADR-0001: nothing here changes the contract. The Enterprise
  repo's same gaps are story C.19 (Draft).
- The method, "Every guard mutation-tested": a mutation is killed only by the
  check it names.

## Design

Admission (`templates/50-admission.yaml`): the deletion exemption only when
the object and the old object both have a spec and they are equal; `kinds`
refuses a VCO CR without a spec; `scope` and `cluster` match only objects with
a spec, so they never fail on evaluation. Comments corrected.

Install checks (bootstrap `_helpers.tpl`): `parent.sharedTenantName` is not
a reserved name; `parent.env` is a DNS label; the SSO roles are unique, not
`fallback`, and each has a `roleCaps` entry (the tenant chart's default roles,
pinned by a render test, plus `tenantValues.roleCaps`); every `roleCaps` value
is one capability list without `sudo`; every `tenantRoleMapping` entry is a
map with a pattern, and `fallback` is `deny`; a set `tenantGroupTemplate` is
not empty; `sso.mount.path` and `.name` are mount path segments; no pattern
holds `"`; `(tenant, role) → group` is one-to-one, within a tenant too
(`{tenant}` alone gives one group all four roles); `parent.token.ttl` ≤
`maxTTL`; mount paths may hold `_`. Schema: `vco`, `kubernetesAuth`,
`templateOperator`, `tenantChart` required; `tenantValues.sso.roles` unique.

Tenant chart: `ttl` ≤ `maxTTL`; a mapping entry that is not a map with a
pattern fails; two roles with one group fail; comments corrected.

Tests and tools: each refusal case in `hack/lab/admission-cases.sh` names the
policy that must refuse it; new UPDATE and deletion cases, and cases for the
issuer PEM, the reviewer ServiceAccount, the JWKS fields,
`authentication.targetNamespace` and the header settings; the offline runner
compiles every expression as a Kubernetes 1.30 API server accepts a new
policy, refuses cost and evaluation errors as refusals, and runs exactly the
pinned number of cases; `hack/mutation_tests.py` names the expected check per
mutation, replaces every match where asked, and times out a hung suite; the
harness walks the schema and tries a misspelt key at every object that refuses
one; `dnsregex` finds every spelling; `version-bump-check.sh` refuses an
absolute or missing path; the hook reports a python3 failure; the `eso`
render's CR count is checked.

## Tests (red first)

- `make admission-offline`: the deletion attack (no spec, then a connection),
  UPDATE cases for kinds and origin, the five rules without a case.
- Harness: `ssogroups` (both role orders, one group for all roles, a string
  mapping, `fallback: allow`, a role without caps, caps with `sudo`, an empty
  template, an empty mount path, a `"`), `installvalues` (every checked value,
  a reserved shared name, `ttl` > `maxTTL`, `kubernetes_prod` accepted),
  `schemakeys`, `quoting` with share roles, `dnsregex`, `bumpcheck`.
- `make mutation-test`: each new guard's mutation killed by its named check.

## Out of scope

The Enterprise repo (C.19). An audience on `vco-admin` (C.17).

## Result (2026-11-04)

- `make verify` green; the golden unchanged.
- `make admission-offline`: 75 cases, 0 failed, each refusal by exactly the
  policy it names, every expression compiled for Kubernetes 1.30.
- `make mutation-test`: 95 mutations, 95 killed by their named check.
- `make admission-test` on the kind lab (Kubernetes 1.33): 75 cases, 0
  failed, 8 offline only (67 run live).
- The attack, live on the lab: a Policy held in deletion by a finalizer; the
  update that removes its spec, and the one that adds a `spec.connection`,
  are both refused by `vco-kinds`; the finalizer removal passes.
- `make e2e-test` on the lab: 33 of 33 steps pass.
- Not adopted: `ne $t1 $t2` in the collision check. With (tenant, role) →
  group one to one, the overlap that gives one tenant one group for two roles
  is refused too, with its own message.

## Done means

The roadmap Done line; `make verify`, `make mutation-test`,
`make admission-test` and the e2e suite green with output seen; docs
corrected; story marked ✅ with this doc linked.
