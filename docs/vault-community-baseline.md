# Vault Community baseline — what Vault Community Edition gives tenancy, and where it stops

**Version:** HashiCorp Vault Community Edition **2.1.1** (released
2026-09-16), the `developer.hashicorp.com/vault/docs` pages at the time of
writing. Configuration through **vault-config-operator (VCO) v1.0.3**
(released 2026-09-29), the Red Hat Community of Practice operator the
Enterprise extension already uses.

Every design decision cites a row here. **VERIFY** marks what the docs did not
settle; each is a task in story C.0 (`docs/planning/C0-live-install-spike.md`).
When Vault or VCO changes, update this file first.

Short source paths are relative to `https://developer.hashicorp.com/vault/`.
Rows marked *(Enterprise lab)* were observed in
`stakater-ab/mto-extension-vault-enterprise`, whose lab runs Community Edition
with `VAULT_EDITION=ce`.

---

## 1. Partitioning

| # | Fact | Consequence | Source |
|---|---|---|---|
| N1 | Namespaces are an Enterprise feature. Community Edition has one root namespace. | No partition per tenant. Everything a tenant has lives beside every other tenant's. | docs/enterprise/namespaces |
| N2 | On Community Edition, Vault **ignores** the namespace a request names and reports success; objects meant for different namespaces land in root and collide (two tenants' `admin` policies become one). | Every object name must carry the tenant. A chart written for namespaces silently breaks on Community. | *(Enterprise lab)* |
| N3 | Mount paths may contain slashes (`team-a/kv`). A mount can't be created under, or over, an existing mount's path. `sys/`, `auth/`, `identity/`, `cubbyhole/` are reserved. | A tenant's mount can be `<tenant>/kv`. A tenant named like a reserved path or an existing platform mount must be refused. | api-docs/system/mounts |
| N4 | Auth methods mount at `auth/<path>`; one Kubernetes or OIDC mount serves any number of roles. | Shared auth mounts work; isolation comes from each role's binding, not from the mount. | docs/auth/kubernetes, docs/auth/jwt |
| N5 | The identity store (entities, groups, aliases), the token store and the policy list are global. | Policy and role names are global and must be tenant-qualified. | docs/concepts/identity |
| N6 | `listing_visibility` on a mount controls whether the UI lists it to unauthenticated users; authenticated users see mounts they hold a capability on through `sys/internal/ui/mounts`. | A tenant sees its own mount in the UI, not others'. **VERIFY** with a token that holds only `<tenant>/kv/...` paths. | api-docs/system/internal-ui-mounts |

## 2. Policies

| # | Fact | Consequence | Source |
|---|---|---|---|
| P1 | ACL policies are path-based; deny by default; `deny` wins over any grant. | Policy is the only wall. | docs/concepts/policies |
| P2 | `*` is a glob **only at the end** of a path and matches any suffix, across segments; `+` matches exactly one segment. | `team-a*` also matches `team-ab/`. Every tenant path must end its tenant segment with `/` before any wildcard. | docs/concepts/policies |
| P3 | Policies can be templated with identity values, e.g. `{{identity.entity.aliases.<accessor>.metadata.service_account_namespace}}`. The Kubernetes alias metadata carries the namespace and ServiceAccount name, not the tenant. | One templated policy can't derive the tenant; per-identity policies stay explicit (ADR-0003). | docs/concepts/policies#templated-policies |
| P4 | `sys/policy/<name>` writes and deletes a policy; ACL paths on it can be narrowed by name prefix (`sys/policy/kv.*`). | The operator's own policy can exclude platform policy names, including its own. | api-docs/system/policy |

## 3. Authentication

| # | Fact | Consequence | Source |
|---|---|---|---|
| A1 | Kubernetes auth roles bind `bound_service_account_names` and `bound_service_account_namespaces`; Vault checks the token with TokenReview. | A role per ServiceAccount, bound to its name and namespace, is safe on a shared mount. | docs/auth/kubernetes |
| A2 | Without `token_reviewer_jwt`, Vault reviews tokens with its own ServiceAccount, which needs `system:auth-delegator`. | No reviewer credential stored. | *(Enterprise lab)* |
| A3 | JWT/OIDC roles bind claims (`bound_claims: {groups: [...]}`) and audiences; one mount and one IdP client can serve every tenant's roles. | One shared SSO mount; a role per tenant tier, bound to that tier's group. | docs/auth/jwt |
| A4 | Token TTLs are per role. | Short-lived workload and SSO tokens, as in the Enterprise extension. | docs/concepts/tokens |

## 4. Engines

| # | Fact | Consequence | Source |
|---|---|---|---|
| E1 | KV v2 keeps versions and metadata; `data/`, `metadata/`, `delete/`, `undelete/`, `destroy/` sub-paths carry the capabilities the tiers need. Mount config (`max_versions`, `cas_required`, `delete_version_after`) is per mount. | A mount per tenant gives a tenant its own KV settings. | docs/secrets/kv/kv-v2 |
| E2 | Disabling a mount deletes all of its data. | Mount deletion is the data-loss operation; the operator must not be allowed to do it (ADR-0005). | api-docs/system/mounts |
| E3 | Transit and PKI are available in Community Edition. | Phase 3, as in the Enterprise extension. | docs/secrets/transit, docs/secrets/pki |
| E4 | Mounts are stored in the mount table. **VERIFY** the table's size limit with integrated storage at hundreds of tenant mounts. | Scale of a mount per tenant. | docs/configuration/storage/raft |

## 5. Operations

| # | Fact | Consequence | Source |
|---|---|---|---|
| O1 | Audit devices are global. Audit filtering and exclusion (1.16+) are **Enterprise**. | One audit log for all tenants. Per-tenant views are filtered downstream by path prefix `<tenant>/`. | docs/enterprise/audit/filtering |
| O2 | Rate-limit quotas exist in Community Edition, can be scoped to a path, and group requests by source address only. Lease-count quotas are Enterprise. | No per-tenant fairness. A per-mount rate limit is possible but coarse. **VERIFY** a quota on `<tenant>/kv`. | docs/concepts/resource-quotas |
| O3 | Vault Community Edition 1.15+ is licensed under the Business Source License 1.1. | Unchanged by the extension. | hashicorp.com/license-faq |
| O4 | OpenBao, the open-source fork, has namespaces since 2.3 (current 2.7.1). | A customer who wants namespaces without Enterprise has a second path: the OpenBao extension. | openbao.org/docs/concepts/namespaces |
| O5 | Enterprise `sys/remount` can move a mount between namespaces. **VERIFY** whether a namespace `team-a` can be created while a root mount `team-a/kv` exists, and whether remount moves it in. | The migration path to Enterprise; designed for, not promised. | api-docs/system/remount |

## 6. vault-config-operator (VCO)

| # | Fact | Consequence | Source |
|---|---|---|---|
| V1 | v1.0.3 has `Policy`, `SecretEngineMount`, `AuthEngineMount`, `KubernetesAuthEngineConfig`/`Role`, `JWTOIDCAuthEngineConfig`/`Role`, `TransitSecretEngineKey`, `PKISecretEngineConfig`/`Role`, `Group`, `GroupAlias`. | Everything the extension renders has a kind. | github.com/redhat-cop/vault-config-operator |
| V2 | VCO mounts engines at `<spec.path>/<spec.name>`; its `Policy` kind writes `sys/policy/<name>`. | `path: team-a`, name `kv` → mount `team-a/kv`. | *(Enterprise lab)* |
| V3 | VCO has **no deletion policy**: deleting a CR deletes the object in Vault. | Data protection is the operator's Vault policy denying `delete` on mounts (ADR-0005). | *(Enterprise lab)* |
| V4 | A mount CR without `spec.config` never gets VCO's finalizer (VCO sends `listingVisibility: ""`, its CRD refuses it), so deleting it deletes nothing. | Every mount sets `config.listingVisibility: hidden`. | *(Enterprise lab)* |
| V5 | VCO status can't show current health: `ReconcileSuccessful` and `ReconcileFailed` coexist, timestamps freeze. | Health is "ever succeeded" and "last error ever", per object. | *(Enterprise lab)* |
| V6 | VCO logs in once, with its own Kubernetes auth role, never a root token. Without `targetNamespace`, objects land in the login namespace — on Community, root. | No `targetNamespace` anywhere in this extension; VCO's login policy is the most powerful identity in the design (ADR-0006). | *(Enterprise lab)* |
| V7 | Drift correction is off by default; with `ENABLE_DRIFT_DETECTION=true` every 10 hours unless `SYNC_PERIOD_SECONDS` is lower. | A policy widened by hand in Vault stays wide until the next drift reconcile. | *(Enterprise lab)* |

## Open questions (VERIFY), owned by story C.0

1. VCO `SecretEngineMount` with `path: <tenant>`, name `kv`, no
   `targetNamespace`: mount created at `<tenant>/kv`, idempotent across
   reconciles, finalizer present. (V2, V4)
1. VCO's least-privilege policy narrowed by name prefix (`sys/policy/kv.*`,
   `auth/kubernetes/workloads/role/kv.*`): does any VCO call need `list` on
   the unnarrowed path? (P4)
1. Mount-table size with 500 tenant mounts on integrated storage. (E4)
1. Vault UI for a token holding only `<tenant>/kv/...`: the mount is listed,
   browsable, and no other tenant's mount appears. (N6)
1. A tenant named like an existing platform mount (`secret`): Vault's error, how
   VCO reports it, how it reaches the TemplateInstance outputs. (N3)
1. ESO `SecretStore` with no namespace and `path: <tenant>/kv`, KV v2.
1. A rate-limit quota on `<tenant>/kv` in Community Edition. (O2)
1. Enterprise migration: a namespace `<tenant>` beside a root mount
   `<tenant>/kv`; `sys/remount` into the namespace. (O5)
1. Who can set `stakater.com/tenant` on a namespace under the customer's
   Multi-Tenant Operator setup (the trust boundary, as in the Enterprise
   extension).
1. VCO drift detection on a `Policy` widened by hand in Vault, on Community
   Edition. (V7)
1. Login with another tenant's Kubernetes role on the shared mount: the error
   Vault returns, so the acceptance suite asserts the right refusal. (A1)
1. Token and entity counts per tenant at scale (one entity per ServiceAccount
   alias on the shared mount). (N5)
