# DX.4 — CI is green on Linux

Story: `docs/roadmap.md` DX.4 (status must be 👍 Approved before this
doc is implemented). Acceptance: none (CI tooling; it runs every check that
proves the acceptance scenarios).

## Why (one paragraph)

On 2026-11-06 the PR's checks were red in CI while every local run was green.
Verify failed from b59afe7 to 7521bb9: CI runs the Makefile's pinned Helm
v3.19.0, which writes schema errors in another form than Helm 3.14 (the local
Homebrew one), and six render checks matched the 3.14 text. The first Kind E2E
run in CI (7521bb9) failed in `make lab-dex`: GNU make 4.3 keeps a
backslash-newline inside single quotes and passes it to the shell, so jq got
`\` in the Dex config program; macOS make 3.81 removes it, so the lab built
locally. Both are differences between a Mac and the Linux runner.

## Governing constraints

- CLAUDE.md test harness rules: no check that can pass on its own failure.
  A check that accepts two message forms must still name the field and the
  rule, as it did.
- CLAUDE.md, "a new guard adds its mutation".
- `HELM_MIN` 3.14 stays, and so does "a system binary wins over the pinned
  download" (Makefile): the checks work with both forms instead.
- The lab's secrets never pass through the shell or a log (`lab-dex`): the
  jq program reads them from the Secrets, as before.

## Design

Helm's schema errors:

| Rule | Helm 3.14 (gojsonschema) | Helm 3.18+ (jsonschema v6) |
|---|---|---|
| type | `- a.b: Invalid type. Expected: object, given: null` | `- at '/a/b': got null, want object` |
| pattern | `- a.b: Does not match pattern '…'` | `- at '/a/b': '…' does not match pattern '…'` |
| unique | `- a.b: array items[0,1] must be unique` | `- at '/a/b': items at 0 and 1 are equal` |
| additional | `- a: Additional property x is not allowed` | `- at '/a': additional properties 'x' not allowed` |
| required | `- (root): x is required` | `- at '': missing property 'x'` |

- `hack/chart-render-tests.sh`: two helpers, `schema_at <err> <a.b>` (an error
  names the field, in either form) and `schema_rule <err> <a.b> <rule> [arg]`
  (the field fails that rule, in either form). The six checks use them:
  `ssogroups` (unique), `notargetns` (additional), `rbacgate` and `toggles`
  and `installvalues` (the field), `installvalues` (pattern), `schemakeys`
  (required). `sg_boot` takes `schema:unique:<a.b>` in place of a message.
- `hack/lab/dex-config.jq`: the Dex config program, moved out of the
  Makefile as it is; `lab-dex` runs `jq -n … -f hack/lab/dex-config.jq`.
- `hack/makefile_recipes.py` with `hack/test_makefile_recipes.py`: a recipe
  line continued with `\` inside single quotes fails `make test`, with its
  line number; the repo's Makefile has none.
- Not changing: the checks' cases, the charts, the Dex config itself.

## Tests (red first)

- Red: the render tests with Helm 3.19 fail six checks (CI's result); the
  new recipe test fails on the Makefile as it is (seven `lab-dex` lines);
  `make lab-dex` under GNU make 4.3, in a container with a fake `kubectl`
  and `helm`, fails with jq's compile errors (CI's result).
- Green: `make verify` with Helm 3.14 and with Helm 3.19; `lab-dex` under GNU
  make 4.3 and under make 3.81 writes the same Dex config Secret; the real
  `make lab-dex` on the kind lab; then CI Verify and Kind E2E on the PR.
- Mutations: in `schema_rule`, each form dropped in turn for the rules the
  checks use (killed by the check's own case under the Helm that writes that
  form); in `makefile_recipes.py`, the in-quote rule (killed by its test).

## Out of scope

Pinning the local Helm to CI's (the "system binary wins" rule): the checks
now accept both. DX.1 (CI as a merge gate).

## Done means

The roadmap Done line; `make verify` green with both Helm versions;
`make mutation-test` green with the pinned Helm, as CI runs it; CI Verify and
Kind E2E green on the PR.

## Result

- Red, as CI: the render tests with Helm 3.19 failed six checks;
  `hack/test_makefile_recipes.py` failed on the Makefile (lines 493 to 499,
  `lab-dex`); `make lab-dex` under GNU make 4.3 (ubuntu:24.04, a fake
  `kubectl` and `helm`) failed with jq's 14 compile errors, as CI's run did.
- Green: the render tests pass with Helm 3.14 and with Helm 3.19 (57 checks,
  then 58 with `schemaforms`); `make verify` green with both (51 Python
  tests; admission cases 109, 26 and 22; `policypaths` for both sets).
- `lab-dex` under GNU make 4.3 and under make 3.81 writes the same
  dex-config Secret, byte for byte, and the same as the old recipe; the real
  `make lab-dex` on the kind lab passes (issuer, 5 redirect URIs, the
  Keycloak connector).
- `HELM=bin/helm make mutation-test` (CI's Helm): 247 mutations, 247 killed
  by their named check; the 15 new ones each by its own case.
- CI on 78f969a: Verify green (`make verify` with 51 Python tests and
  `schemaforms`; `make mutation-test` 247 of 247 killed; the version, ADR and
  story checks), run 42216462330. Kind E2E green, the first CI run to pass:
  the lab built on Linux, then 33 of 33 steps, 104 admission cases live, run
  42216474137.
