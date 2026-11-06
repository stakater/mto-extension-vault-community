# C.24 — A null value on `--reuse-values`

Story: `docs/roadmap.md` C.24 (status must be 👍 Approved before this
doc is implemented). Acceptance: AC-ISO-11 (the admission policies stay on when
the operator means the default).

## Why (one paragraph)

C.21 made a null or commented-out toggle take the chart default
(`admission.enabled` on, `parent.eso` enabled), and `charts/README.md` says so.
That holds for a values file and for `--set`, but not on
`helm upgrade --reuse-values`. In the smoke run of 2026-11-06 with Helm 3.14.0,
after `--set parent.eso=disabled`, `helm upgrade --reuse-values --set
parent.eso=null` stored `eso: null`, but Helm computed `disabled` from the old
value (`helm get values --all`), the chart never got the null, and ESO stayed
off. The same upgrade without `--reuse-values`, with a values file that holds
`eso: null`, gave `enabled` within 8 s. An operator who resets
`admission.enabled` this way, after turning it off, keeps the wall off.

## Governing constraints

- CLAUDE.md "Docs move with the code": the README must say what is true.
- C.21 (null is the default) stays: the chart's behaviour does not change.
- No invariant is touched: no rendered object changes.

## Design

- `charts/README.md`: one paragraph after the bootstrap values table, "Null
  and `--reuse-values`": what Helm does, the evidence, and the two upgrades
  that reset a value (the value itself; or all values again without
  `--reuse-values`). The `admission.enabled` passage and the `parent.eso` row
  point to it.
- `charts/mto-extension-vault-community-bootstrap/values.yaml`: the comment on
  `admission.enabled` says the same in one line, because `helm show values`
  prints it.
- Not changing: any template, helper, schema or rendered object. The chart's
  version is not bumped for a comment (the charts are unreleased, at 0.1.0).

## Tests (red first)

None: the change is docs only, and the behaviour is Helm's. It needs a
stored release, so no offline check can show it; the evidence is the live run
above. The existing render check `nulltoggle` still pins the chart side (a null
renders the default).

## Out of scope

Changing the chart so that `--reuse-values` with a null resets the value:
the chart never gets the null, so it cannot. Enterprise has the same Helm
behaviour; C.19 tracks the Enterprise gaps.

## Done means

The roadmap Done line; `make verify` green (markdownlint, links, the render
tests unchanged).

## Result

- `charts/README.md`: the paragraph "Null and `--reuse-values`" after the
  bootstrap values table; the `admission.enabled` passage and the `parent.eso`
  row point to it. `values.yaml`: the `admission.enabled` comment says it.
- `make verify` green: markdownlint, links, method, 34 Python tests, the
  render tests and the admission cases (109, 26, 22) unchanged.
