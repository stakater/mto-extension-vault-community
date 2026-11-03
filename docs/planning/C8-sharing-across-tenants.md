# C.8 — Sharing across tenants

Story: `docs/roadmap.md` C.8 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-SHR-3.

## Why (one paragraph)

Two tenants sometimes must exchange a value — a partner's API endpoint, a
hand-off token. They must not reach each other's mounts to do it. The
Enterprise extension gives each ordered pair of tenants a folder in the shared
namespace, `from-<a>/to-<b>/`, which `a`'s exporting app writes and `b`'s
importing app reads. This story ports it to `shared/kv`, with the share roles
on each tenant's own auth mount (ADR-0007).

## Governing constraints

- ADR-0007: share roles live on `auth/<tenant>/kubernetes/workloads`; there
  is no shared auth mount; a share login uses `VAULT_K8S_MOUNT`, and
  `VAULT_OUT_<PEER>_NAMESPACE` / `VAULT_IN_<PEER>_NAMESPACE` are empty.
- ADR-0001 and invariant 7: the annotations `kv-export-tenant`,
  `kv-import-tenant`, `kv-import.<name>`, the names
  `share.<tenant>.<ns>.<sa>.<out|in>.<peer>`, the SecretStore
  `<sa>.share-<peer>-vault` and the ConfigMap keys are the Enterprise ones.
- ADR-0003, design §4: an export policy writes only
  `shared/kv/{data,metadata}/<env>/from-<t>/to-<p>/*`; an import policy reads
  only `…/from-<p>/to-<t>/*`. The admission policies already hold this.
- A share to a peer not in the roster (`knownTenants`) renders nothing and
  self-heals when the peer appears; a Deployment importing from it is told.

## Design

Tenant chart, from the Enterprise templates:

- `_helpers.tpl`: `kv-export-tenant` and `kv-import-tenant` join the accepted
  keys, refused with KV off; `vault.shareOutName`, `vault.shareInName`,
  `vault.peerEmittable` ported.
- `04-sa-share-out.yaml` and `04-sa-share-in.yaml`: Policy and
  `KubernetesAuthEngineRole` per peer, the role on the tenant's own mount with
  the same namespace binding as the workload role, the policy through the
  scope check. The eso slice renders the import SecretStore: `path: shared/kv`,
  `mountPath: <tenant>/kubernetes/workloads`, the share-in role.
- `04-sa-own-tenant.yaml`: `VAULT_OUT_<PEER>_NAMESPACE` (empty), `_ROLE`,
  `_PATH` and the same for `VAULT_IN_<PEER>_*`.
- `05-deployment-externalsecrets.yaml`: the `kv-import.<name>` form
  (`<peer>/<leaf>[#<key>]` → `<env>/from-<peer>/to-<tenant>/<leaf>` in the
  import store), refused when the ServiceAccount does not import from the
  peer, or the peer is not in the roster.

## Tests (red first)

Render: `shares` (export and import policies on `shared/kv` in their own
direction, roles on the tenant's own mount, the import store on `shared/kv`),
`rolebind` and `policyscope` over the share objects, the guard cases (share
annotations with KV off, a rejected ServiceAccount gets no share objects, an
off-roster import), `contract` with the C.8 delta lines removed — the delta
file is then empty but for the monitoring line (C.11); the golden regenerated.

Live: e2e-alpha's `web` exports to e2e-beta and writes
`shared/kv/data/dev/from-e2e-alpha/to-e2e-beta/`, logging in with its share
role at its own mount (`VAULT_K8S_MOUNT`); e2e-beta's `reader` imports and
reads it, through ESO into a pod, and can't write it; each is refused the
other's share role; the reverse direction and the prefix tenant `e2e` are
refused.

Mutation: let the import policy write; the import step's write refusal must
fail.

## Out of scope

Shares to the shared mount's own prefix by a person (SSO roles cover a
tenant's mount only).

## Done means

The roadmap Done line; `make verify` green; golden regenerated; e2e green;
`charts/README.md` updated; story marked ✅ with this doc linked.
