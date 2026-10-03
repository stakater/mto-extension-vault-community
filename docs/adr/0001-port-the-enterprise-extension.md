# ADR-0001: Port the Enterprise extension

- **Status:** Proposed
- **Date:** 2026-10-03

## Context

`mto-extension-vault-enterprise` is built and tested: two Helm charts rendering
vault-config-operator (VCO) CRs through Template Operator v2, a workload
annotation contract shared with the OpenBao extension, four tiers, SSO, sharing,
ESO delivery, a 39-check render harness and an e2e suite. Its isolation is a
Vault namespace per tenant, which Community Edition doesn't have (N1); on
Community its objects collide in root while reporting success (N2).

The original proposal for this extension suggested one extension with an
`edition: Community | Enterprise` switch on a new `VaultIntegration` CRD, so the
user experience stays identical.

## Decision

- Build this extension as a **port** of the Enterprise charts: same chart
  shape, same VCO kinds, same annotations, tiers, name families, ConfigMap
  keys, `tenantValues` mechanism, harness and e2e rules. Change only what
  `design.md` §2 names.
- **A separate repository for now**, with a render check (story C.5) that
  fails on any drift from the pinned Enterprise chart's contract. Story C.15
  decides whether to merge.
- **No new CRD.** Configuration stays Helm values under `parent` and
  `tenantValues`, as in every current extension. The proposal's `VaultIntegration`
  CRD is not adopted.

## Consequences

- Workloads don't know the edition: same annotations, same ConfigMap keys, so
  moving a tenant between editions changes no manifest (the data move is
  C.16).
- Two charts to keep in step until C.15; the parity check makes drift a red
  build, not a surprise.
- Every Enterprise fix needs a port decision — tracked by the parity check
  and by porting stories, not by memory.

## Alternatives

- **One chart with `isolation.strategy: path | namespace` now.** Deferred, not
  rejected: it is where the parity evidence may lead (C.15). Doing it first
  would put an untested strategy inside a tested chart.
- **A `VaultIntegration` CRD with an `edition` field.** Rejected: the extension
  pattern is Helm values rendered by Template Operator; a CRD needs a
  controller to read it.
- **A new design from scratch.** Rejected: the Enterprise charts already
  encode dozens of measured VCO and Template Operator behaviours.
