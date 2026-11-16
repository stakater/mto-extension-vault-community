# C.21 — The fourth review, closed

Story: `docs/roadmap.md` C.21 (👍 Approved by Ayesha Arshad, 2026-11-05).
Acceptance: AC-ISO-6, AC-ISO-11, AC-ISO-12.

## Why (one paragraph)

A fourth review, of commit b59afe7 (C.17, C.18, C.20), found two critical
defects. First, a null toggle reads as "false": `admission:` with its child
commented out, or `admission: {enabled: }`, renders none of the four admission
policies, and the install is green; a null `parent.eso` turns ESO off. Second,
an admission refusal case passes when any rule of the named policy refuses
it, so three rules that stop an escalation (one-line stanzas, an SSO role's
own policy, the shared name) and about twelve more can be removed with every
case green; with each removed, an attack is admitted. Important: values that
render unquoted (`vco.role` and `vco.authPath`, the reviewer ServiceAccount,
the client secret key, the refresh interval, the tenant label key, a tenant's
slice key) install and then fail every tenant; a `tenantValues.ssoToken` TTL
set on one side installs and then Vault refuses every SSO role; the mutation
runner counts an evaluation error as a kill and can't test its own evaluator;
some guards have no mutation; two comments claim a safety that is not there.
Suggestions came with them. The method turns review findings into a story;
this is it.

## Governing constraints

- Invariant 5 and ADR-0008: every VCO CR in `vault-config` passes admission,
  so a value that turns admission off must never be a silent default.
- Invariant 1 and ADR-0003: each copy of the scope check fails on its own bad
  input; a refusal case pins the rule that refuses it.
- Invariant 7 and ADR-0001: nothing here changes an annotation, a role, a name
  or a ConfigMap key. Quoting a value, a stricter install check and a refusal
  of an empty role list are not contract lines. The Enterprise repo's gaps are
  story C.19.
- The method, "Every guard mutation-tested": a mutation is killed only by its
  own case, never by a crash or another guard's case.
- K8s fact (k8s.io/apiserver v0.36.3, `validating/dispatcher.go:289-292`): a
  policy's refusal reports its first failed validation only, live and
  offline, so a message names one rule.

## Design

Null toggles (bootstrap `templates/_helpers.tpl`): `boolValue` takes the
chart default for a null or absent value (`admission.enabled` "true",
`parent.sso.enabled` and a tenant feature "false"); `esoMode` takes "enabled".
The `templateSync` precedent: absent or null is the chart default.

Admission (`templates/50-admission.yaml`, `hack/lab/admission-cases.sh`,
`hack/admission-eval/main.go`):

- A refusal case is `refuse:<policy>:<rule>`; the script maps each rule to the
  text of its validation's message and writes it as `# message:`. Offline and
  live, a refusal counts only with that message. The runner's FAIL line says
  why: admitted, refused by another rule, refused on an evaluation error, or
  also refused by another policy.
- The kinds policy's rules after "has a spec" hold for an object without one,
  so a CR without a spec is refused by that rule, never by an error.
- New cases, each refused or admitted by one rule only: two stanzas on one
  line; an SSO role that attaches `vco-admin`; a kv policy for the shared
  name; a kv name with three parts; a role with
  a `targetNamespaces` list, and one with `matchExpressions`; an SSO role on
  another mount; a kv mount with another name, another object name, and a
  path that is not a tenant name; a Kubernetes auth mount with another name,
  and one under a reserved name; an OIDC config on another mount; a
  Kubernetes auth config on another path and with another name; a config with
  the cluster's own CA, and one with an empty reviewer name (admitted); a
  deleting object that Template Operator moves to a tenant's TemplateInstance
  with a spec change; a deleting Kubernetes auth config whose host changes; a
  Kubernetes auth config without a spec; a cluster-scoped `redhatcop.redhat.io`
  object of another operator, as a person and as Template Operator (admitted,
  offline only: the lab has no such CRD). After the re-review: an SSO policy
  on every path; a path under `kv/subkeys`; a share policy with another
  direction than `in` or `out`; a kv policy whose `spec.name` puts a regex in
  the tenant part; an SSO role with a kv name, and one with a share name; a
  userpass mount in the OIDC mount's place; an OIDC auth mount with another
  name; a Kubernetes auth mount below a path that is not a tenant; a kv mount
  that logs response data in clear.
- `$vcoPath` is trimmed of `/`, as the tenant chart and the parent now render
  it.
- In `make admission-offline`, the charts' own render meets the CEL: for two
  install value sets, the parent and the tenant chart (core and eso) render
  with the bootstrap's values, and every VCO CR runs as an admit case, written
  by Template Operator with its source label. The number of CRs is pinned per
  set, so a lost parent or lost SSO objects fail.
- The evaluator prints each result on one line: a policy's expressions keep
  their newlines, and an error that quotes one ended the line early.
- `gone` reads only "not found" as gone; the EXIT trap deletes an object a
  stopped case still holds and drops only `$HOLD`, so VCO's finalizer stays;
  a live run first releases any object a killed run left held.

Quoting (tenant chart, parent), with Sprig's `quote`, which keeps a null
empty: `vco.authPath`, `vco.role`, `vco.serviceAccount` in the parent,
`kubernetesAuth.kubernetesHost` and `.tokenReviewerServiceAccount`,
`sso.oidc.clientSecretRef.key`, `externalSecretRefreshInterval`, the slice key
and the Vault path of an ExternalSecret, `vaultServer`, and the tenant label
key where it is a YAML key.

Install checks (bootstrap): `vco.authPath` trimmed of `/` where it is
rendered; `kubernetesAuth.tokenReviewerServiceAccount` a ServiceAccount name
when set; `tenantValues.ssoToken` ttl and maxTTL compared, a side not set
taking the tenant chart's default (`defaultSsoToken`, 15m and 1h), a value
Vault can't read refused (the parser reads every form Vault's parseutil
reads: seconds, `<n>d`, Go durations with `+`, `.5h`, `1.h`, `µs` and `μs`);
`tenantValues.sso.roles` not empty with SSO on; `kubernetesAuth.kubernetesHost`
and `tenantChart.version` set (a null deletes the key before the schema's
`minLength` sees it); the tenant chart's default SSO mount and group pattern
in one helper each, pinned by `tenantvaluekeys`.

Tenant chart: `ssoToken.ttl` over `maxTTL` fails; SSO on with no roles fails;
`vco.authPath` trimmed.

Mutation runner (`hack/mutation_tests.py`): a crash is never a kill, with or
without `detail` (render), and an admission case failed by a policy that
refused on an evaluation error or failed to configure is never a kill; a FAIL
line that holds Helm's `fail` output, a
refused near miss or a fixture that did not render is no kill without
`detail`; a mutation of `hack/admission-eval` runs the admission suite with
the copy's own evaluator; a `go` suite runs `go test ./hack/admission-eval/`,
whose tests pin the evaluator's own rules.

Render tests (`hack/chart-render-tests.sh`): the bootstrap renders at setup,
before any check; `nulltoggle`; `typeprobe` (VCO's login, the API host, the
reviewer, the client secret key, the refresh interval, a slice key, the Vault
address and the tenant label key, each as a string YAML reads as a number,
keep the type of the base render's field, and no map key is a number);
`ssotoken`; new
`installvalues`, `ssogroups` and `mountagree` cases; the negative checks that
accepted any Helm error name the message.

E2E (`tests/e2e`): the admission step pins the names of the offline-only
cases; the AC-ISO-10 step asserts the `__no_namespace__` binding itself, and
creates e2e-beta's namespace before the held role, so VCO's first look finds
a namespace of that name with another tenant's label;
`.github/workflows/e2e.yaml` runs on an approval only for the PR's head
commit.

Not changing: the contract, the golden, the ADRs.

## Tests (red first)

- `make admission-offline`: every new case, and the message on every
  refusal, before the policy changes.
- Harness: `nulltoggle`, `typeprobe`, `ssotoken`, the new `installvalues`,
  `ssogroups`, `mountagree` and `tenantvaluekeys` cases.
- `go test ./hack/admission-eval/`: a refusal by another rule, an evaluation
  error and another policy's refusal fail a case; a wrong case count fails.
- `make test`: the runner's crash and weak-kill rules.
- `make mutation-test`: every new mutation killed by its own case.

## Out of scope

The Enterprise repo (C.19). An audience on `vco-admin` (C.17). A wait for the
API server to load new policies after an upgrade: the docs say what the
result means right after one.

## Result (2026-11-05)

Red, before the fixes:

- `admission:` with its child commented out rendered 0 policies and 0
  bindings, and the install was green.
- With the one-line stanza rule, the SSO role's own-policy check or the
  shared-name check removed, the 77 cases stayed green, and an attack case
  for each (two stanzas on one line, an SSO role with `vco-admin`, a kv policy
  for the shared name) was admitted.
- `vco.role: "1e3"` installed and rendered a float in all 24 VCO CRs of a
  tenant. A one-sided `tenantValues.ssoToken` TTL installed.
- `cel-has-spec` counted as killed on an evaluation error.

Green, after:

- `make verify` green; the golden unchanged.
- `make admission-offline`: 109 cases, 0 failed; the charts' own render
  admitted, exactly 26 VCO CRs for the default install and 22 for the custom
  one.
- `make mutation-test`: 219 mutations, 219 killed by their named check.
  The full run gave 218; `eval-admitted` counted as weak there, because the
  new one-line helper called `Error()` on a nil error and its test panicked.
  With the helper nil-safe, it is killed by its own test.
- `make admission-test` on the kind lab (Kubernetes 1.33): 109 cases, 0
  failed, 5 offline only (104 run live), the new deletion cases on a real old
  object among them.
- `make e2e-test` on the lab: 33 of 33 steps pass; the admission step pins
  104 live cases and the 5 offline-only ones by name, and AC-ISO-10 sees
  `["__no_namespace__"]` with e2e-beta's namespace there first.

Re-review of this change (four agents, 2026-11-05): the fixes held, and it
found more rules with no case of their own (above, red first: 8 of the 9 new
mutations survived before their cases), the rendered phase pinned to its own
count, a parent probe that rendered no TemplateInstance, `vco.serviceAccount`
and two mount names not probed, a null API host or chart version that
installs, an empty `sso.roles` refused with SSO off, durations Vault reads
that the parser refused, admission crashes on admit lines and in other
policies counted as kills, FAIL lines cut at a newline, the EXIT trap dropping
VCO's finalizer, and stale comments. All fixed here.

Not adopted:

- The admission template's own quote check (`50-admission.yaml`, the list
  before the policies) stays as a second guard. For `vco.role`,
  `vco.authPath` and `vco.serviceAccount` it fires before the install check,
  so the install check's case for a quote in `vco.role` runs with admission
  off. It is not listed in `hack/mutation_tests.py`.
- The "roles must be a list" guard is not listed: without it the render
  crashes, and a crash is never a kill. Its case (`roles-string`) stays.
- For the same reason, guards whose removal gives only an evaluation error
  are not listed: the scope and cluster policies' `has-spec` match conditions
  (the kinds policy refuses a CR without a spec first), `has()` on
  `spec.authentication`, its `serviceAccount` and `OIDCDiscoveryURL`, and the
  `sso.` family's kind check (a Kubernetes role with an `sso.` name errors in
  the role rule).
- The e2e job does not compare its checkout with the approved commit: that
  needs `fetch-depth: 2` for the merge commit's parent, and CI can't be run
  here. The new step compares the approval with the head in the event.
- No wait for the API server to load new policies after an upgrade: the docs
  say what a run right after one means.

## Done means

The roadmap Done line; `make verify`, `make mutation-test` and
`make admission-test` on the lab green with output seen; golden unchanged;
docs corrected (`design.md`, `charts/README.md`, `acceptance.md`, the C.20
planning doc where it is wrong); story marked ✅ with this doc linked.
