# C.0 — Live-install spike

Story: `docs/roadmap.md` C.0 (👍 Approved by Ayesha Arshad on 2026-11-02;
🔨 In progress).
Acceptance: none directly; it decides whether the AC-ISO scenarios are
achievable as designed on Community Edition.

## Why (one paragraph)

The design ports a tested Enterprise extension onto an edition with no
namespaces, and rests on VCO and Vault behaviour we read or inferred but did not
observe on Community Edition: VCO creating `<tenant>/kv` without a target
namespace, its policy narrowed by object name, the mount table at scale, the UI
for a token that holds one mount. Twelve questions (`vault-community-baseline.md`,
"Open questions") are load-bearing. Answer them before porting a chart, so the
port doesn't carry an Enterprise assumption into Community.

## Governing constraints

- ADR-0001..0006 are all Proposed; this spike moves each to Accepted or writes
  a superseding ADR.
- Baseline: Vault Community 2.1.1, VCO v1.0.3. Record exact versions, the
  Kubernetes version, and the VCO policy used.
- Secrets by reference: no tokens, unseal keys or client secrets in the
  findings doc.

## Design

Environment: the Enterprise repo's lab, which already runs Community Edition —
`make lab-up VAULT_EDITION=ce` in `stakater/mto-extension-vault-enterprise`
(kind 1.33, cert-manager, Template Operator v2 0.0.7, ESO, Reloader, VCO
v1.0.3, Keycloak and Dex). Instead of the Enterprise charts, apply by hand the
objects design §3 describes for two tenants `team-a`, `team-b` and a prefix
tenant `team`; give VCO the policy in design §6.

| # | Question | How | If the answer is "no" |
|---|---|---|---|
| 1 | VCO creates `<tenant>/kv` with no target namespace, idempotently, with its finalizer | apply the CR; two drift reconciles; delete under the lab's broad policy | mount name `<tenant>-kv`; or patch VCO upstream |
| 2 | VCO works with a name-narrowed policy | run with design §6; watch for 403s on `list` | add the narrowest `list` lines; record which |
| 3 | Mount table at 500 tenants | script 500 mounts on integrated storage; measure | shared mount with prefixes for large installs — new ADR |
| 4 | UI for a one-mount token | log in as an SSO editor; screenshot | document the CLI path; file upstream |
| 5 | Tenant named like a platform mount | create `secret` tenant with `secret/` mounted | widen the reserved list default |
| 6 | ESO with `path: <tenant>/kv`, no namespace | one ExternalSecret | adjust the SecretStore template |
| 7 | Rate-limit quota on `<tenant>/kv` | create; exceed | document as unavailable |
| 8 | Namespace beside `<tenant>/kv`; remount into it | not needed: the extension is Community only (2026-11-03) | C.16 becomes copy-based, not remount |
| 9 | Who can set `stakater.com/tenant` | check the customer's Multi-Tenant Operator webhook and roles | same trust note as Enterprise |
| 10 | VCO drift detection reverts a hand-widened policy | `ENABLE_DRIFT_DETECTION=true`, short `SYNC_PERIOD_SECONDS` | document the window |
| 11 | Error for another tenant's role | log in `web` with `kv.team-b...` | assert the observed error in AC-ISO-5 |
| 12 | Entities and tokens per tenant at scale | count after 100 ServiceAccounts log in | sizing note |

Also run AC-ISO-1, -2, -3, -5, -7 and -9 by hand.

**Second run** (added 2026-11-02, after the first run's findings, on the same
lab; Template Operator v2 built from the local `template-operator-v2` `main`,
because its published chart is not readable): verify the whole design against
the Enterprise and OpenBao extensions for least privilege and data isolation,
with an independent review of the design given the code, not the first run's
conclusions.

| # | Question | How | If the answer is "no" |
|---|---|---|---|
| 5b | A VCO error at the TemplateInstance outputs | a Template with a colliding mount and a refused policy | health from VCO CRs directly |
| 13 | A namespace name reused by another tenant gets nothing | delete a tenant namespace, re-create it with another tenant's label, log in | bind roles by name and tenant label |
| 14 | VCO's policy can pin mount types | `allowed_parameters` on the mount paths; right and wrong types | document the gap |
| 15 | Cross-tenant shares hold (AC-SHR-3) | the Enterprise share policies with full paths | fix the share rule |
| 16 | The name-narrowed policy bounds VCO | a `kv.*` policy granting `*` and a `kv.*` role; log in | bound VCO's input at admission |
| 17 | One auth mount per tenant, at the Enterprise path with the tenant prefix | mount, config, role, ESO, offboarding through VCO | keep a shared mount |
| 18 | The scope check as admission | ValidatingAdmissionPolicies; good and bad CRs; a tenant's Template | a validating webhook |
| 19 | VCO's login can't be used from another namespace | a VCO CR elsewhere naming a `vco-admin` ServiceAccount | bind the role to `vault-config` |

Run the acceptance scenarios again on the result, and AC-SHR-3.

Output: `docs/spikes/c0-findings.md` — one section per question: setup,
commands, observed output, answer, design consequence. Then ADR status changes
and design edits in the same PR.

## Tests (red first)

None in code. The spike's "tests" are the questions and the hand-run
acceptance scenarios; each finding records pass/fail with evidence. The
second run's checks are scripts in `docs/spikes/c0/` (`acceptance.sh`,
`q18-admission.sh`); each refusal is paired with an allow.

## Out of scope

Porting the charts (C.1 onward). Transit and PKI.

## Done means

All questions answered with evidence (question 8 is not needed: the
extension is Community only); every ADR Accepted or superseded;
`design.md` and `vault-community-baseline.md` updated; roadmap C.0 marked ✅
with a link to the findings.
