# ADR-0006: Bound the operator by name and type, and what it is asked at admission

- **Status:** Accepted
- **Date:** 2026-10-03; revised 2026-11-02 after story C.0; accepted 2026-11-03

## Context

VCO writes every policy, role and mount the extension needs (V1, V6). On
Enterprise its login lives in root and writes into child namespaces, so its
policy reaches tenant namespaces (`+/sys/policy/*`) but never root's own
policies, mounts or auth methods: whatever it writes stays inside one tenant.
On Community Edition there is only root. A VCO allowed `sys/policy/*` could
rewrite its own policy, `default`, or any platform policy; allowed `delete` on
mounts, it could destroy data.

Narrowing by name is not enough on its own. C.0 showed that two CRs whose
names pass — a `kv.*` policy granting `path "*"` with `sudo`, and a `kv.*`
role bound to any ServiceAccount — give a token close to root (P6, Q16). And
Template Operator applies objects into `vault-config` for a Template in any
namespace (T2).

## Decision

1. **VCO's Vault policy is narrowed by object name and mount type** (design
   §6):
    - policies only under `sys/policy/kv.*`, `share.*`, `sso.*`;
    - roles only under those prefixes, and only on the extension's mounts —
      `kv.*` on `auth/<tenant>/kubernetes/workloads`, `share.*` on
      `auth/shared/kubernetes/workloads`, `sso.*` on `auth/<tenant>/oidc/sso` —
      never on `auth/kubernetes`, where VCO's own login role lives;
    - kv mounts only `sys/mounts/+/kv`, create, read, update — never delete;
    - auth mounts only `sys/auth/+/kubernetes/workloads` and
      `sys/auth/+/oidc/sso`, with delete (they hold grants);
    - every mount's `type` pinned with `allowed_parameters` (P5).
1. **What VCO is asked is bounded at admission.** ValidatingAdmissionPolicies
   on the VCO CRs in `vault-config` apply the scope check (ADR-0003) to every
   CR's content and refuse a CR that Template Operator writes for a
   TemplateInstance outside `vault-config` (design §4).
1. **VCO's token and pod are treated as root-equivalent.** Its login role binds
   `vco-admin` in `vault-config` only (V13); nobody else may create tokens for
   that ServiceAccount or exec into VCO.

## Consequences

- VCO can't write its own policy or login role directly, can't touch platform
  policies, can't destroy a tenant's data, and can't mount another engine or
  auth method in the extension's places.
- No CR that leaves its tenant's scope reaches VCO, whoever writes it — the
  charts, Template Operator, a person.
- VCO's own token is not bounded: a compromised VCO is a compromised Vault.
  This is weaker than Enterprise, and is stated in design §10.
- Every new name family or mount (Transit, PKI) needs a matching line in the
  Vault policy and in the admission policies — checked by the e2e suite
  running with the production policy.
- The admission policies need Kubernetes 1.30 or later (K2).

## Alternatives

- **`sys/policy/*` and `sys/mounts/*` (a wide operator policy).** Rejected:
  self-escalation and data loss one bug away.
- **The name-narrowed policy alone** (this ADR's first text). Rejected: it
  bounds names, not grants (P6).
- **Templated or Vault-side content checks.** Not available: Vault Community
  has no Sentinel or endpoint governing policies, and parameter constraints
  see only top-level keys (P5).
- **A validating webhook instead of ValidatingAdmissionPolicy.** Rejected: a
  service to run and secure, for checks CEL expresses.
- **A root token for VCO.** Rejected: never, on any edition.
