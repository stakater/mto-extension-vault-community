# CLAUDE.md

Guidance for working in this repository.

## What this is

**The Vault Community Edition extension for the Multi-Tenant Operator.** It
gives every Multi-Tenant Operator `Tenant` a secret scope in one shared Vault
Community — its own KV mount, a policy and login role per annotated
ServiceAccount, SSO in four roles, opt-in sharing — with no per-tenant manual
work. Community Edition has no namespaces, so a tenant is a path prefix —
its KV mount `<tenant>/kv`, its auth mounts `auth/<tenant>/…`, policies and
roles — not a Vault namespace.

It is a **port of `stakater/mto-extension-vault-enterprise`**: the same Helm
charts shape, the same vault-config-operator (VCO) CRs, and the same workload
contract (annotations, roles, names, ConfigMap keys). `docs/design.md` §2 lists
the only three differences.

## Status: Phases 1 and 2 done

C.0, the live-install spike, is done (`docs/spikes/c0-findings.md`). ADRs 0001,
0003, 0004, 0005, 0007 and 0008 are Accepted; 0007 and 0008 supersede 0002 and
0006 (share roles on the tenant's own mount). C.1 to C.11, C.17, C.18, C.20, C.21 and DX.2 are done
(`docs/roadmap.md`): both charts, the admission policies, the lab, and an e2e
suite that proves them on Vault Community 2.1.1 (`make e2e-kind`). `make
verify` is the gate: markdownlint, relative links, the method checks, chart
lint, the render tests (`hack/chart-render-tests.sh`), CRD validation against
the vendored VCO CRDs, and the admission policies' CEL run offline
(`make admission-offline`). CI runs it on every PR, plus the mutation run
(`make mutation-test`: every guard listed in `hack/mutation_tests.py`,
weakened, must fail the check it names), the version-bump, ADR-immutability
and story-citation checks. A new guard adds its mutation there.

In a Claude Code session, a PostToolUse hook (`.claude/settings.json`,
`hack/claude-post-edit.sh`) runs `make method links` after every edit to a
Markdown file of this repository, and shows a failure at once.

## Invariants — never violate these

1. **Every rendered policy and role passes the scope check** (design §4,
   ADR-0003): every path inside the tenant's mount `<tenant>/kv/` or its named
   shares in `shared/kv/`; the tenant segment closed by `/` before any
   wildcard; no `+`; nothing under `sys/`, `auth/`, `identity/`, `cubbyhole/`;
   a role binds only its own policy, its tenant's mount and its namespace by
   name and tenant label. A violation fails the render, and the admission
   policies refuse it at the API server.
1. **Every name is tenant-qualified** in one of the Enterprise name families
   (`kv.` 4 parts, `share.` 6, `sso.` 3). Community Edition has one namespace;
   an unqualified name collides across tenants (baseline N2).
1. **No `Namespace` CR and no `targetNamespace`** anywhere.
1. **Tenants never administer Vault** (ADR-0004): no role writes policies,
   mounts, auth or identity.
1. **VCO is bounded by name and type, its input at admission** (ADR-0008):
   it can't write a policy outside the three families, can't touch
   `auth/kubernetes`, can't delete a kv mount, can't mount another type. Its
   policy does not bound what a policy grants, so VCO's token is
   root-equivalent and every VCO CR in `vault-config` passes the admission
   policies.
1. **Data outlives definitions** (ADR-0005): the tenant mount is rendered by the
   parent; VCO is denied kv mount deletion; purge is a Vault-admin act.
1. **Contract parity with Enterprise** (ADR-0001): a change to annotations,
   roles, names or ConfigMap keys is made in both repos or not at all.

## Legacy — do not model on these

The Vault (`IntegrationConfig`) and ArgoCD (`Extensions` CR) integrations in
tenant-operator are legacy and being removed, including the KV-path-per-tenant
Vault integration. Never read, cite or copy them. The models are
`mto-extension-vault-enterprise` and `mto-extension-openbao`.

## Documentation map

| Doc | What it is |
|---|---|
| `docs/vision.md` | **Read first.** Why this exists, for whom, the value, non-goals. |
| `docs/concepts.md` | Terms, the running example, and Enterprise vs Community side by side. |
| `docs/method.md` | How this is built — and where each rule is enforced: story → plan → red → green → verify → validate → review. |
| `docs/roadmap.md` | Phases and user stories with lifecycle status. |
| `docs/acceptance.md` | The isolation contract as testable scenarios. |
| `docs/design.md` | The delta from Enterprise: rendered objects, the scope check, tenant names, VCO's policy, lifecycle, limits. |
| `docs/vault-community-baseline.md` | What Vault Community 2.1.1 and VCO v1.0.3 give tenancy, with sources; open questions. |
| `docs/diagrams.md` | C4 and sequence diagrams. |
| `docs/adr/` | Architecture Decision Records. |
| `docs/planning/` | One planning doc per story, from `TEMPLATE.md`. |

**ADRs are immutable once accepted.** Supersede, don't edit.

## Workflow for any change (in order)

1. **Story** in `docs/roadmap.md`, 📝 Draft until a human approves.
1. **Planning doc** from `docs/planning/TEMPLATE.md`, committed first.
1. **Red first.** A failing render check or e2e assertion, then the change.
1. **Verify.** `make verify` green, output seen; docs updated in the same change,
   story marked ✅ with the planning doc linked.
1. **Review.** An adversarial `/code-review` before merge, plus a code owner's
   approval (`.github/CODEOWNERS`). Defects found become stories.

The full method, and where each rule is enforced, is `docs/method.md`.

## Conventions inherited from mto-extension-vault-enterprise

Read its `CLAUDE.md`; every rule there applies once the charts land — the test
harness rules (no check that can pass on its own failure, mutation-test every
guard), the e2e rules (assert as the workload, a denial is a 403 with a
matching allow), dot-joined names, quoted tenant-derived values, toggles only
through `vault.on`, `tenantValues` as the only path to a tenant chart value,
version bumps, vendored VCO CRDs.

## Boundaries

- Baseline: Vault Community **2.1.1**, VCO **v1.0.3**. When either changes,
  update `docs/vault-community-baseline.md` first, then the design.
- Secrets by reference only. No token, unseal key or client secret in any file.
- Feature branches only; PRs cite the story code (CI fails otherwise) or say
  `No story: <reason>`.
