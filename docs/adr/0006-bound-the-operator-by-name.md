# ADR-0006: Bound the operator by name

- **Status:** Proposed
- **Date:** 2026-10-03

## Context

VCO writes every policy, role and mount the extension needs (V1, V6). On
Enterprise its login lives in root and writes into child namespaces, so its
policy reaches tenant namespaces (`+/sys/policy/*`) but never root's own
policies, mounts or auth methods: it can't widen itself. On Community Edition
there is only root. A VCO allowed `sys/policy/*` could rewrite its own policy,
`default`, or any platform policy; allowed `delete` on mounts, it could destroy
data.

## Decision

VCO's policy (design §6) is narrowed **by object name**:

- policies only under `sys/policy/kv.*`, `share.*`, `sso.*`;
- roles only under those prefixes, and only on the workload and SSO mounts —
  never on `auth/kubernetes`, where VCO's own login role lives;
- mounts only `sys/mounts/+/kv`, create, read, update — never delete;
- auth mounts only the two the bootstrap chart names.

## Consequences

- VCO can't rewrite its own policy or login role, can't touch platform
  policies, and can't destroy a tenant's data.
- Every new name family or mount (Transit, PKI) needs a matching line here —
  checked by the e2e suite running with the production policy.
- Whoever can create VCO CRs in the config namespace can still create a tenant
  mount under any one-segment prefix: platform trust, the same as on
  Enterprise.

## Alternatives

- **`sys/policy/*` and `sys/mounts/*` (a wide operator policy).** Rejected:
  self-escalation and data loss one bug away.
- **A root token for VCO.** Rejected: never, on any edition.
