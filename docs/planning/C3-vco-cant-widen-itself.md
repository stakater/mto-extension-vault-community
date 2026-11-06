# C.3 — VCO can't widen itself

Story: `docs/roadmap.md` C.3 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-ISO-7, AC-ISO-11, AC-ISO-12, AC-LIFE-4.

## Why (one paragraph)

VCO writes every policy, role and mount, in the same Vault namespace as
everything else. On Community Edition nothing in Vault stops a `kv.*` policy
from granting `path "*"` (P6, Q16), and a Template in a tenant namespace can
make Template Operator write VCO CRs into `vault-config` (T2, Q18b). C.0
proved both bounds on a live install with hand-written objects. This story
ships them: the production VCO policy as a file, and the admission policies
as part of the bootstrap chart, so every install has them.

## Governing constraints

- ADR-0008 (supersedes ADR-0006): VCO's policy is narrowed by name and mount
  type; `share.*` roles live on each tenant's own mount (ADR-0007); what VCO
  is asked is bounded at admission; VCO's token is root-equivalent.
- ADR-0003: the scope check also runs at the API server.
- ADR-0005: VCO has no `delete` on `sys/mounts/+/kv`.
- ADR-0004: tenants never administer Vault.
- P5: `allowed_parameters` pins a mount's `type`; P6: names don't bound grants.
- K2: ValidatingAdmissionPolicy needs Kubernetes 1.30.
- T2: a Template's `targetNamespaces` gates the TI, not the rendered objects;
  Template Operator overwrites `templates.v2.stakater.com/instance-namespace`.
- V11: VCO injects its pod's CA into a Kubernetes auth config, but keeps a CA
  the CR supplies.

## Design

- `charts/examples/vco-admin-policy.hcl`: design §6 as a file, with comments:
  kv mounts create, read, update (no delete), type `kv`; auth mounts at
  `+/kubernetes/workloads` (type `kubernetes`) and `+/oidc/sso` (type `oidc`);
  `kv.*` and `share.*` roles on `auth/+/kubernetes/workloads`, `sso.*` roles
  on `auth/+/oidc/sso`; `sys/policy/{kv,share,sso}.*`.
- `charts/mto-extension-vault-community-bootstrap/templates/50-admission.yaml`:
  three `ValidatingAdmissionPolicy` objects and their bindings, ported from
  `docs/spikes/c0/q18-admission.yaml` and rendered from the install's values:
    - `…-vco-origin`: a VCO CR in `configNamespace` that Template Operator writes
      (`templateOperator.namespace`/`.serviceAccountName`) carries
      `templates.v2.stakater.com/instance-namespace: <configNamespace>`;
    - `…-vco-scope`: design §4 for Policies, both role kinds, both mount kinds
      and the OIDC config — names in a family, one-line stanzas, no `sudo`,
      paths in scope, roles bound to their own policy, their tenant's mount,
      their ServiceAccount and a selector of exactly the namespace name and
      `parent.tenantLabelKey`; SSO roles bound to exactly the group the install's
      pattern gives; mounts of the extension's shapes only; the OIDC config at
      `parent.sso.issuerUrl` only;
    - `…-vco-cluster`: a Kubernetes auth config names
      `kubernetesAuth.kubernetesHost`, a CA equal to `kube-root-ca.crt` in
      `configNamespace`, and no reviewer other than
      `kubernetesAuth.tokenReviewerServiceAccount`.

  Failure policy `Fail`; deletions and VCO's finalizer updates pass. A value
  `admission.enabled` (default `true`) exists only for clusters below 1.30;
  turning it off is documented as removing the wall.
- `00-rbac.yaml` unchanged: admission policies are installed by Helm, not by
  Template Operator.

## Tests (red first)

Render:

- `admission`: the bootstrap renders the three policies and bindings; the
  rendered CEL names the install's Template Operator ServiceAccount, config
  namespace, tenant label key, API host, issuer and group pattern (each
  changed in a values file and seen in the output).
- `vcopolicy`: `charts/examples/vco-admin-policy.hcl` and the lab policy
  differ only by the kv mount `delete`; neither grants `sys/policy/*`,
  `sys/mounts/*`, `auth/kubernetes`, `auth/token` or `sys/policy/vco-admin`;
  every mount path pins its type.
- `policyscope` (C.2) keeps the render side: no policy name outside the three
  families.

Live, added to the e2e suite:

- the production policy, loaded into Vault under a check name with a token
  holding only it: refused `sys/policy/vco-admin`, `sys/policy/default`, a
  `transit` mount at `<t>/kv`, a `secrets disable` of a tenant's kv mount, a
  role on `auth/kubernetes`; allowed a `kv.*` policy and a kv mount (the
  matching allows) (AC-ISO-7, AC-LIFE-4);
- a `kv.*` Policy CR granting `path "*"`, a role bound to another tenant's
  label, and a role on another tenant's mount, applied to `vault-config` as a
  cluster admin: refused at admission; the same objects in scope: admitted
  with a server-side dry run (AC-ISO-11);
- a Template and TemplateInstance in a tenant namespace that render a Policy
  into `vault-config`: the Policy never appears (AC-ISO-12).

Mutation: drop the `sudo` rule, the selector rule and the origin match from
the rendered policies; each named live check and render check goes red.

## Out of scope

Rotating VCO's own credentials; Vault audit of VCO; an admission webhook (a
service to run, for checks CEL expresses).

## Done means

The roadmap Done line; `make verify` green; the e2e suite green with the new
steps; `charts/README.md` "Vault bootstrap" and "Admission" written; story
marked ✅ with this doc linked.
