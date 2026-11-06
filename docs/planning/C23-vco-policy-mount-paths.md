# C.23 — VCO's policy for other mount paths

Story: `docs/roadmap.md` C.23 (status must be 👍 Approved before this
doc is implemented). Acceptance: AC-ISO-7 (VCO can't widen itself: its policy
is the one the docs give).

## Why (one paragraph)

`charts/README.md` lists `kubernetesAuth.path`, `kubernetesAuth.name` and
`tenantValues.sso.mount` as settings. But `charts/examples/vco-admin-policy.hcl`
(production) and `hack/lab/vco-admin-policy.hcl` (lab) name only the default
mounts, `+/kubernetes/workloads` and `+/oidc/sso`, and no doc says to change
them. In the smoke run of 2026-11-06, a token with the example policy got
`deny` on `sys/auth/<tenant>/k8s/apps` and on the roles under it, so with the
workload mount at `k8s/apps` every tenant's auth mount fails. With the policy
changed by hand, the whole e2e suite passed on those values.

## Governing constraints

- ADR-0008 and CLAUDE.md invariant 5: VCO is bounded by name and mount type.
  The fix must keep every bound: no wider path, no new capability.
- CLAUDE.md invariant 4: no tenant role administers Vault. Unchanged.
- CLAUDE.md, "a new guard adds its mutation": the new check gets mutations.
- `design.md` §6 is the policy's design; it gets the same note.

## Design

- `charts/README.md`, "Vault bootstrap": the policy names the default mounts;
  with other values, replace every `kubernetes/workloads` with
  `<kubernetesAuth.path>/<kubernetesAuth.name>` and every `oidc/sso` with
  `<sso.mount.path>/<sso.mount.name>`, without the slashes around them. The
  `kubernetesAuth.path` row points to it.
- `charts/examples/vco-admin-policy.hcl`: the header says the same.
- `docs/design.md` §6: one sentence.
- New `hack/vco-policy-covers.py`: reads the rendered VCO CRs (JSON, one per
  line), maps each to the Vault paths VCO writes, and checks that each path is
  matched by exactly one `path` stanza of each policy file, and that the stanza
  allows a write (`create` or `update`). `--replace old=new` applies the
  README's rule to the policy text first. The mapping, from the CRs and VCO's
  calls seen on the lab:

  | CR | Vault path |
  |---|---|
  | SecretEngineMount | `sys/mounts/<path>/<name>` and `…/tune` |
  | AuthEngineMount | `sys/auth/<path>/<name>` and `…/tune` |
  | KubernetesAuthEngineConfig | `auth/<path>/<name>/config` |
  | KubernetesAuthEngineRole | `auth/<path>/role/<name>` |
  | JWTOIDCAuthEngineConfig | `auth/<path>/config` |
  | JWTOIDCAuthEngineRole | `auth/<path>/role/<name>` |
  | Policy | `sys/policy/<spec.name or metadata.name>` |

  Vault's globs: `+` is one path segment, a final `*` a prefix. A kind the
  helper does not map fails.
- `hack/admission-offline.sh`, after each render: the default set against both
  policies as they are; the custom set against both with the README's rule for
  its values (`k8s/apps`, `sso-x/login`). Failures print
  `FAIL  policypaths <set>: …`.
- Not changing: the policies' paths and capabilities, the charts.

## Tests (red first)

- Red: the custom set against the example policy without the rule fails
  (F1 itself); then the README's rule makes it pass.
- `hack/test_vco_policy_covers.py` (`make test`): `+` matches one segment
  only; a final `*` is a prefix; two matching stanzas fail; a read-only stanza
  is no write; an unknown kind fails; `--replace` is applied before the match.
- Mutations: in the example policy, the workload auth mount path, an SSO role
  path, and the write capability of `sys/policy/kv.*`; in the lab policy, a
  workload role path (each killed by `policypaths`); in the helper, the
  one-segment `+`, the one-stanza rule and the write rule (each killed by its
  unit test).

## Out of scope

Rendering the policy from the chart (the Done line's other option): the policy
is written once by a Vault admin before the install, so a rendered copy would
still have to be copied by hand. VCO's own login mount (`vco.authPath`) is not
in the policy's paths, so it needs no rule.

## Done means

The roadmap Done line; `make verify` green with `policypaths` for both sets;
the new mutations killed; no chart template change, so no version bump.

## Result

- Red: `policypaths custom` without the README's rule: 28 failures, every
  auth mount and every role under it, in both policies (F1 itself). The
  default set passed: 26 VCO CRs, 30 Vault paths.
- Green: with the rule, the custom set passes (22 CRs, 26 paths), and the
  default set as before. `hack/test_vco_policy_covers.py`: 11 tests.
- `python3 hack/mutation_tests.py` with the nine new ids: 9 killed by their
  named check: four on the policy files and one on the README rule, by
  `policypaths`; four on the helper, by its unit tests.
- Live: both changed policy files load into the lab Vault (16 `path`
  stanzas in the example). The rule was already proven live in the smoke run
  of 2026-11-06: with the policies changed by exactly this rule, the e2e suite
  passed 32 steps against `k8s/apps` and `sso-x/login`.
- Docs: `charts/README.md` ("Other mount paths", the `kubernetesAuth.path`
  row), the headers of both policy files, `design.md` §6.
