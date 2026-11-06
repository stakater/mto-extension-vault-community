# ADR-0003: The policy is the wall, so every policy is checked

- **Status:** Accepted
- **Date:** 2026-10-03; revised 2026-11-02 after story C.0; accepted 2026-11-03

## Context

On Enterprise, a mistake in a tenant's policy stays inside the tenant's
namespace. On Community Edition there is no namespace: a policy path one
character too wide reaches another tenant (P1, P2). The original proposal used
one policy per tenant (`mto-tenant-acme`, the whole tenant path) attached to one
Kubernetes auth role bound to all of the tenant's namespaces. Vault can template
policies with identity metadata, but the Kubernetes alias carries the
namespace and ServiceAccount, not the tenant (P3).

## Decision

- **Per-identity policies, as in Enterprise:** one policy and role per
  annotated ServiceAccount, scoped to its own app's prefix; tenant-wide scope
  only for people's SSO roles.
- **Every rendered policy passes the scope check** (design §4): every path
  inside the tenant's mount or its named shares, in the share's direction;
  tenant segment closed by `/` before any wildcard; no `+`; no `sys/`, `auth/`,
  `identity/`, `cubbyhole/`; one-line stanzas, no `sudo`; names in a
  tenant-qualified family. **Every rendered role passes it too**: its own
  policy only, its tenant's mount, its own ServiceAccount, its namespace by
  name and tenant label; an SSO role, exactly its tenant's group.
- Enforced in the template (a violating object fails the render), in the
  render harness (`policyscope`, mutation-tested), **and at the API server**
  by ValidatingAdmissionPolicies on the VCO CRs in `vault-config`, which hold
  for any writer (ADR-0006). Deterministic; nothing advisory decides it.

## Consequences

- The one wall Community Edition has is never written by hand and never
  rendered unchecked.
- Two apps in one namespace can't read each other — stronger than the
  proposal's tenant-wide workload policy.
- More policies (one per ServiceAccount) — the same count as Enterprise.
- A policy written by hand in Vault, outside the extension, is not checked.
  Documented in `design.md` §10; drift detection (V7) reverts edits to the
  extension's own policies.

## Alternatives

- **One policy per tenant for all workloads (the proposal).** Rejected: every
  app in the tenant reads every other app's secrets; a single compromised pod
  exposes the tenant.
- **Templated policies.** Rejected: the tenant isn't in the identity metadata;
  a namespace-derived path would leak the namespace layout into the boundary.
- **Trust review instead of a check.** Rejected: the failure mode is one
  character; only a mechanical check catches it every time.
