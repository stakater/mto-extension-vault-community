# C.5 — Contract parity with Enterprise

Story: `docs/roadmap.md` C.5 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-PAR-1.

## Why (one paragraph)

A platform that moves a tenant between editions, or runs both, needs the
workload contract to be the same: the annotations an app team writes, the
role names, the object names, and the ConfigMap keys an app reads. Today
parity rests on review. Enterprise main already renamed `tier` to `role`
(`e303ba0`) without this repo noticing until C.0 closed. This story makes
drift a failing check.

## Governing constraints

- ADR-0001 and CLAUDE.md invariant 7: a change to annotations, roles, names or
  ConfigMap keys is made in both repos or not at all.
- Design §2: the only intended differences are paths (the tenant prefix) and
  the empty `VAULT_NAMESPACE`; values are not part of the contract, keys are.
- Port, don't redesign: the Enterprise chart is the reference, pinned by
  commit, like the vendored VCO CRDs.

## Design

- `hack/contract.sh <tenant-chart-dir>` renders a chart with one contract
  fixture (embedded in the script, so both charts get the same input) and
  prints the contract, one sorted line per item, with every fixture value
  replaced by a placeholder (`<tenant>`, `<peer>`, `<ns>`, `<sa>`, `<app>`,
  `<name>`, `<NS>`, `<PEER>`):
    - `annotation.serviceaccount <key>`, read from the chart's own error
      message for an unknown key (the list the chart enforces);
    - `annotation.deployment <form>`, the same, for a Deployment;
    - `role <name>`, the `roleCaps` keys;
    - `object <Kind> <namespace>/<name>` for every object rendered;
    - `configmap.key <KEY>`, the keys of every `vault-config-<sa>`.
- `hack/enterprise-contract.txt`: the output for the Enterprise tenant chart at
  a pinned commit, with the commit in its header. `make contract-sync
  ENTERPRISE_SRC=… ENTERPRISE_REF=…` regenerates it from a checkout, without
  switching its branch (`git archive`).
- `hack/contract-delta.txt`: the allowed difference, each line `-` (Enterprise
  only) or `+` (this chart only) with the story that removes it. While C.6,
  C.7 and C.8 are not ported, their items are listed there; each of those
  stories deletes its lines. The check fails if the real difference is not
  exactly the listed one — in either direction, so a stale line fails too.
- `hack/chart-render-tests.sh` gains `contract`, and runs `contract.sh` on
  this chart.

## Tests (red first)

`contract` runs before the delta file exists and fails, naming every
difference; the delta file is then written with a reason per line. Mutation:
rename a ConfigMap key, add an annotation key, rename the role name family;
each fails `contract`. Remove a delta line and see `contract` fail.

## Out of scope

Comparing values (paths differ by design); the Enterprise repo's own check
in the other direction (an Enterprise story).

## Done means

The roadmap Done line; `make verify` green; `contract` mutation-tested;
`docs/acceptance.md` AC-PAR-1 cites the check; story marked ✅ with this doc
linked.
