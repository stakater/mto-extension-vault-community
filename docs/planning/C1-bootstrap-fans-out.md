# C.1 — Bootstrap fans out, tenant mounts appear

Story: `docs/roadmap.md` C.1 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-LIFE-1, AC-ISO-8.

## Why (one paragraph)

Nothing is installable yet. The platform team needs one Helm install that
watches every MTO `Tenant` and gives each valid tenant its own KV mount
`<tenant>/kv`, plus the shared mount `shared/kv` and the shared auth mount for
cross-tenant shares, with no step per tenant. This story ports the Enterprise
bootstrap chart and the check tooling (`make`, render tests, CRD validation,
CI) that every later story builds on.

## Governing constraints

- ADR-0001: port, don't redesign. Start from Enterprise `main` (`72f425c`),
  change only what design §2 names.
- ADR-0002: a tenant is a mount prefix. The parent renders `<tenant>/kv` per
  valid Tenant, and `shared/kv` and `auth/shared/kubernetes/workloads` once.
- ADR-0005: the kv mount lives as long as the Tenant CR, so the parent renders
  it, never the tenant chart.
- CLAUDE.md invariant 3: no `Namespace` CR and no `targetNamespace`.
- CLAUDE.md invariant 2: names stay tenant-qualified (`<tenant>-kv`).
- Design §5: reserved tenant names are skipped and listed.
- Baseline N3, N7, N8: a mount nested under another mount is refused, in the
  secrets table and the auth table; Vault 2.1.1 mounts `agent-registry/`.
- V6: a CR without `targetNamespace` lands in root, the only namespace.

## Design

New chart `charts/mto-extension-vault-community-bootstrap/`, ported from
`charts/mto-extension-vault-enterprise-bootstrap/`:

- `values.yaml`, `values.schema.json`, `_helpers.tpl`: Enterprise's, renamed.
  `vco.namespace` is removed (Community has one namespace). New value
  `parent.reservedPaths` (design §5).
- `templates/00-rbac.yaml`, `10-vco-identity.yaml`, `20-child-template.yaml`,
  `40-parent-templateinstance.yaml`: Enterprise's, renamed. The VCO kind list
  has no `Namespace`.
- `templates/30-parent-template.yaml`: parameters lose `vcoNamespace`, gain
  `reservedNames` (the fixed list, `token`, the first segment of
  `vco.authPath`, and `parent.reservedPaths`).
- `files/parent-gotemplate.tpl`: no `Namespace` CR, no `targetNamespace`.
  Per valid tenant:

  ```yaml
  kind: SecretEngineMount
  metadata: { name: "team-a-kv", namespace: vault-config, labels: { stakater.com/tenant: "team-a" } }
  spec: { path: "team-a", name: kv, type: kv, config: { listingVisibility: hidden }, options: { version: "2" } }
  ```

  Once: `shared-kv` (`path: shared`), `shared-kubernetes`
  (`AuthEngineMount`, `path: shared/kubernetes`, `name: workloads`) and
  `shared-kubernetes-config`. A tenant named in the reserved list is skipped
  with the reason in `mto-extension-vault-community-skipped-tenants`.

New skeleton chart `charts/mto-extension-vault-community/` (Chart.yaml,
values, schema, `_helpers.tpl`), so the child Templates have a chart to pull.
It renders nothing until C.2.

Tooling, ported: `hack/chart-render-tests.sh` (the checks that apply to the
bootstrap and the parent), `hack/crd-validate.sh` and `hack/crd-validate/`,
`hack/vco-crds/` (seven kinds, from the VCO v1.0.3 release chart),
`hack/release-chart.sh`, `hack/version-bump-check.sh`, `go.mod`. The `Makefile`
gains the chart targets; `make verify` runs them with the docs checks. CI:
`.github/workflows/pull_request.yaml` sets up Go and runs `make verify` and
`version-bump-check`; `push.yaml` releases the charts.

Not changing: the annotation contract, the child TI names and parameters, the
outputs, the drift-protection block, `tenantValues`.

## Tests (red first)

Render checks written before the chart, each failing on an empty chart:

- `emission`: one core TI and one `.eso` TI per tenant with a labelled
  namespace; none for a tenant without one; the roster lists exactly the
  rendered tenants (AC-LIFE-1).
- `reserved`: `sys`, `auth`, `token`, `kubernetes`, `agent-registry`, a
  `parent.reservedPaths` entry, `shared`, a dotted name and a 64-character name
  are skipped and listed; a valid name next to them renders (AC-ISO-8).
- `notargetns`: no `Namespace` kind and no `targetNamespace` in any render.
- `parentmounts`: the parent's VCO objects are exactly `<t>-kv` per valid
  tenant plus `shared-kv`, `shared-kubernetes`, `shared-kubernetes-config`,
  with the paths above; a tenant without a labelled namespace still has its
  mount (`datalifetime`).
- Ported: `templateset`, `rbacgate`, `rbaccover`, `toggles`, `nullfields`,
  `versionpin`, `outputnames`, `tenantname`, `tenantvalues` (bootstrap part),
  `ssoissuer`, `removedkeys` (bootstrap part), `listingvis`, `release`,
  `bumpcheck`, `fullnames`.
- `crd-validate`: the parent render against the vendored CRDs, exact count.

Mutation test: remove the reserved-name branch in the parent gotemplate and
see `reserved` fail; add a `targetNamespace` and see `notargetns` fail.

## Out of scope

The tenant chart's objects (C.2 onward), the admission policies and VCO's
policy (C.3), the lab and the e2e suite (C.2), the e2e workflow (C.2).

## Done means

The roadmap Done line; `make verify` green with its output seen; mutation
tests run; `README.md`, `CLAUDE.md` (status), `charts/README.md` started;
story marked ✅ with this doc linked.
