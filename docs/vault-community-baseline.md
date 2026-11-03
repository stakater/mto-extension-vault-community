# Vault Community baseline — what Vault Community Edition gives tenancy, and where it stops

**Version:** HashiCorp Vault Community Edition **2.1.1** (released
2026-09-16), the `developer.hashicorp.com/vault/docs` pages at the time of
writing. Configuration through **vault-config-operator (VCO) v1.0.3**
(released 2026-09-29), the Red Hat Community of Practice operator the
Enterprise extension already uses.

Every design decision cites a row here. **VERIFY** marks what the docs did not
settle; each was a task in story C.0 (`docs/planning/C0-live-install-spike.md`).
Rows marked *(C.0)* were observed on the C.0 live install on 2026-11-02;
the evidence is in [`spikes/c0-findings.md`](spikes/c0-findings.md).
When Vault or VCO changes, update this file first.

Short source paths are relative to `https://developer.hashicorp.com/vault/`.
Rows marked *(Enterprise lab)* were observed in
`stakater/mto-extension-vault-enterprise`, whose lab runs Community Edition
with `VAULT_EDITION=ce`.

---

## 1. Partitioning

| # | Fact | Consequence | Source |
|---|---|---|---|
| N1 | Namespaces are an Enterprise feature. Community Edition has one root namespace. | No partition per tenant. Everything a tenant has lives beside every other tenant's. | docs/enterprise/namespaces |
| N2 | On Community Edition, Vault **ignores** the namespace a request names and reports success; objects meant for different namespaces land in root and collide (two tenants' `admin` policies become one). | Every object name must carry the tenant. A chart written for namespaces silently breaks on Community. | *(Enterprise lab)* |
| N3 | Mount paths may contain slashes (`team-a/kv`). A mount can't be created under, or over, an existing mount's path. `sys/`, `auth/`, `identity/`, `cubbyhole/` are reserved. | A tenant's mount can be `<tenant>/kv`. A tenant named like a reserved path or an existing platform mount must be refused. | api-docs/system/mounts |
| N4 | Auth methods mount at `auth/<path>`; one Kubernetes or OIDC mount serves any number of roles. | A shared auth mount would work, with isolation from each role's binding. The extension still mounts one per tenant, so offboarding can revoke the tenant's tokens (A6). | docs/auth/kubernetes, docs/auth/jwt |
| N5 | The identity store (entities, groups, aliases), the token store and the policy list are global. | Policy and role names are global and must be tenant-qualified. | docs/concepts/identity |
| N6 | `listing_visibility` on a mount controls whether the UI lists it to unauthenticated users; authenticated users see mounts they hold a capability on through `sys/internal/ui/mounts`. A token with only `team-a/kv/...` paths sees `team-a/kv/` and `cubbyhole/` in the UI, browses its mount, and gets 403 on `team-b/kv`. | A tenant sees its own mount in the UI, not others'. | api-docs/system/internal-ui-mounts; *(C.0 Q4)* |
| N7 | An auth mount can't be created under an existing auth mount: with `auth/kubernetes` enabled, `sys/auth/kubernetes/workloads` returns 400 `path is already in use at kubernetes/`. | In root, the extension's auth mounts can't sit under VCO's login mount or a platform's `auth/oidc`. They go at `auth/<tenant>/kubernetes/workloads` and `auth/<tenant>/oidc/sso`, which nest under nothing unless a tenant is named like the first segment of a platform auth mount (`kubernetes`, `token`, …): reserved names. | *(C.0 Q1b, Q17)* |
| N8 | Vault 2.1.1 mounts `agent-registry/` (type `agent_registry`) on its own and adds a policy `default-ceiling`. A mount under `agent-registry/` is refused (`cannot mount`). | `agent-registry` is a reserved tenant name. | *(C.0 Q5)* |
| N9 | A Kubernetes auth login creates one entity and alias per ServiceAccount UID (`alias_name_source: serviceaccount_uid`). Entities are not removed with the ServiceAccount; a re-created ServiceAccount gets a new one. | Entities grow with ServiceAccount churn, in the one identity store. | *(C.0 Q12)* |

## 2. Policies

| # | Fact | Consequence | Source |
|---|---|---|---|
| P1 | ACL policies are path-based; deny by default; `deny` wins over any grant. | Policy is the only wall. | docs/concepts/policies |
| P2 | `*` is a glob **only at the end** of a path and matches any suffix, across segments; `+` matches exactly one segment. A token with `path "team*"` reads `team-a/kv/data/...`. | `team-a*` also matches `team-ab/`. Every tenant path must end its tenant segment with `/` before any wildcard. | docs/concepts/policies; *(C.0)* |
| P3 | Policies can be templated with identity values, e.g. `{{identity.entity.aliases.<accessor>.metadata.service_account_namespace}}`. The Kubernetes alias metadata carries the namespace and ServiceAccount name, not the tenant. | One templated policy can't derive the tenant; per-identity policies stay explicit (ADR-0003). | docs/concepts/policies#templated-policies |
| P4 | `sys/policy/<name>` writes and deletes a policy; ACL paths on it can be narrowed by name prefix (`sys/policy/kv.*`). | The operator's own policy can exclude platform policy names, including its own. | api-docs/system/policy |
| P5 | `allowed_parameters` restricts a path's top-level request parameters: `"type" = ["kv"], "*" = []` on `sys/mounts/+/kv` refuses another engine type with 403 and leaves VCO's creates and tunes working. Nested keys (`config.*`) can't be restricted. | VCO's policy pins the type of every mount it may create; mount config is pinned at admission. | docs/concepts/policies#parameter-constraints; *(C.0 Q14)* |
| P6 | A policy's name bounds nothing about its content. A writer allowed `sys/policy/kv.*` and `auth/<mount>/role/kv.*` can create `path "*"` with `sudo` and bind it to an identity it controls: that token wrote a platform policy, read another tenant and tuned a tenant mount. | On Community, VCO's identity is close to root. The scope check must bound the content where VCO's CRs are written: at admission (design §4). | *(C.0 Q16)* |

## 3. Authentication

| # | Fact | Consequence | Source |
|---|---|---|---|
| A1 | Kubernetes auth roles bind `bound_service_account_names` and `bound_service_account_namespaces`; Vault checks the token with TokenReview. Another ServiceAccount's token on a role gets 403 `service account name not authorized`. A namespace deleted and re-created under the same name by another tenant passes a binding by name, and read the first tenant's secret. | A role per ServiceAccount, bound to its name and namespace, keeps ServiceAccounts apart; the namespace must also be bound by its tenant label (V10). | docs/auth/kubernetes; *(C.0 Q11, Q13)* |
| A2 | Without `token_reviewer_jwt`, Vault reviews tokens with its own ServiceAccount, which needs `system:auth-delegator`. | No reviewer credential stored. | *(Enterprise lab)* |
| A3 | JWT/OIDC roles bind claims (`bound_claims: {groups: [...]}`) and audiences; one mount and one IdP client can serve every tenant's roles. | One IdP client serves every tenant's SSO mount (`auth/<tenant>/oidc/sso`, one per tenant for revocation, A6); a role per tenant role, bound to that role's group. | docs/auth/jwt |
| A4 | Token TTLs are per role. Each login is one service token, alive for its TTL; ESO reuses its token across refreshes. | Short-lived workload and SSO tokens, as in the Enterprise extension. | docs/concepts/tokens; *(C.0 Q12)* |
| A5 | Vault 2.1.1 warns on a Kubernetes auth role without `audience`. | Binding an audience is a hardening option; each workload must then request its token with that audience. | *(C.0)* |
| A6 | Disabling an auth mount revokes every token issued through it: the old token got 403. Deleting a role does not: its tokens live to their TTL. | One auth mount per tenant, so offboarding revokes the tenant's tokens, as on Enterprise. | api-docs/system/auth; *(C.0 Q17)* |

## 4. Engines

| # | Fact | Consequence | Source |
|---|---|---|---|
| E1 | KV v2 keeps versions and metadata; `data/`, `metadata/`, `delete/`, `undelete/`, `destroy/` sub-paths carry the capabilities the roles need. Mount config (`max_versions`, `cas_required`, `delete_version_after`) is per mount. | A mount per tenant gives a tenant its own KV settings. | docs/secrets/kv/kv-v2 |
| E2 | Disabling a mount deletes all of its data. | Mount deletion is the data-loss operation; the operator must not be allowed to do it (ADR-0005). | api-docs/system/mounts |
| E3 | Transit and PKI are available in Community Edition. | Phase 3, as in the Enterprise extension. | docs/secrets/transit, docs/secrets/pki |
| E4 | Mounts are stored in the mount table. On integrated storage it grows about 53 bytes per mount, linearly to 5000 (265 KB); a new mount takes 114 ms at 500 and 209 ms at 5000; restart is 2–3 s. Each mount change writes the whole table to the Raft log. Raft's `max_entry_size` defaults to 1 MiB. | A mount per tenant scales to thousands of tenants; the table's ceiling is near 19 000 mounts by arithmetic. | docs/configuration/storage/raft; *(C.0 Q3)* |

## 5. Operations

| # | Fact | Consequence | Source |
|---|---|---|---|
| O1 | Audit devices are global. Audit filtering and exclusion (1.16+) are **Enterprise**. | One audit log for all tenants. Per-tenant views are filtered downstream by path prefix `<tenant>/`. | docs/enterprise/audit/filtering |
| O2 | Rate-limit quotas exist in Community Edition, can be scoped to a path, and group requests by source address only. A quota on `team-a/kv/` returns 429 past its rate and leaves `team-b/kv/` alone; `group_by` other than `ip`, `secondary_rate` and lease-count quotas are refused as Enterprise-only. | No per-tenant fairness. A per-mount rate limit is possible but coarse. | docs/concepts/resource-quotas; *(C.0 Q7)* |
| O3 | Vault Community Edition 1.15+ is licensed under the Business Source License 1.1. | Unchanged by the extension. | hashicorp.com/license-faq |
| O4 | OpenBao, the open-source fork, has namespaces since 2.3 (current 2.7.1). | A customer who wants namespaces without Enterprise has a second path: the OpenBao extension. | openbao.org/docs/concepts/namespaces |
| O5 | Enterprise `sys/remount` can move a mount between namespaces. **VERIFY** whether a namespace `team-a` can be created while a root mount `team-a/kv` exists, and whether remount moves it in. | The migration path to Enterprise; designed for, not promised. | api-docs/system/remount |

## 6. vault-config-operator (VCO)

| # | Fact | Consequence | Source |
|---|---|---|---|
| V1 | v1.0.3 has `Policy`, `SecretEngineMount`, `AuthEngineMount`, `KubernetesAuthEngineConfig`/`Role`, `JWTOIDCAuthEngineConfig`/`Role`, `TransitSecretEngineKey`, `PKISecretEngineConfig`/`Role`, `Group`, `GroupAlias`. | Everything the extension renders has a kind. | github.com/redhat-cop/vault-config-operator |
| V2 | VCO mounts engines at `<spec.path>/<spec.name>`; its `Policy` kind writes `sys/policy/<name>`. On Community Edition with no `targetNamespace`, `path: team-a`, name `kv` gives `team-a/kv/`, stable across drift reconciles, with VCO's finalizer. | `path: team-a`, name `kv` → mount `team-a/kv`. | *(Enterprise lab)*; *(C.0 Q1)* |
| V3 | VCO has **no deletion policy**: deleting a CR deletes the object in Vault. | Data protection is the operator's Vault policy denying `delete` on mounts (ADR-0005). | *(Enterprise lab)* |
| V4 | A mount CR without `spec.config` never gets VCO's finalizer (VCO sends `listingVisibility: ""`, its CRD refuses it), so deleting it deletes nothing. | Every mount sets `config.listingVisibility: hidden`. | *(Enterprise lab)* |
| V5 | VCO status can't show current health: `ReconcileSuccessful` and `ReconcileFailed` coexist, timestamps freeze. | Health is "ever succeeded" and "last error ever", per object. | *(Enterprise lab)* |
| V6 | VCO logs in once, with its own Kubernetes auth role, never a root token. Without `targetNamespace`, objects land in the login namespace — on Community, root. | No `targetNamespace` anywhere in this extension; VCO's login policy is the most powerful identity in the design (ADR-0006). | *(Enterprise lab)* |
| V7 | Drift correction is off by default; with `ENABLE_DRIFT_DETECTION=true` every 10 hours unless `SYNC_PERIOD_SECONDS` is lower. At 30 s, a policy and a role widened by hand were reverted in 19 s. | A policy widened by hand in Vault stays wide until the next drift reconcile. | *(Enterprise lab)*; *(C.0 Q10)* |
| V8 | A CR whose write Vault refuses gets no finalizer; the error is on its status (`ReconcileFailed`) and no other CR is affected. | A tenant name that collides with a mount fails alone, and deleting its CR is clean. | *(C.0 Q5)* |
| V9 | With the name-narrowed policy (design §6), every kind the charts render reconciles, creates and deletes; no call needs `list` or another path. A refused mount delete leaves the CR `Terminating` and is retried, each retry a 403. | The narrowed policy is sufficient. The admin purge ends the retries. | *(C.0 Q2, Q17)* |
| V10 | `KubernetesAuthEngineRole` `targetNamespaces.targetNamespaceSelector` is resolved by VCO to namespace names. VCO watches namespaces: a deleted or relabelled namespace leaves the role within seconds, as `__no_namespace__` when none match. VCO's CRD has no field for Vault's own `bound_service_account_namespace_selector`. | Bind each role by `kubernetes.io/metadata.name` AND `stakater.com/tenant`. A label change made while VCO is down is seen when VCO returns. | *(C.0 Q13)* |
| V11 | VCO's webhooks: a role's `spec.path` can't change (`spec.path cannot be updated`). A `KubernetesAuthEngineConfig` gets `useOperatorPodCA: true` and VCO's pod CA (equal to `kube-root-ca.crt`), but a CA set in the CR is kept. | Moving a role to another mount is a delete and a create. The admission policy pins the CA. | *(C.0 Q17, Q18)* |
| V12 | VCO re-creates a mount disabled by hand while its CR is live, within one sync period and empty. Under a `Terminating` CR it does not. | The admin purge disables a mount only after its CR is deleted. | *(C.0)* |
| V13 | VCO's login role binds `vco-admin` in `vault-config`. A VCO CR in another namespace naming a ServiceAccount `vco-admin` there gets 403 `namespace not authorized`. | A VCO CR outside `vault-config` acts with its own ServiceAccount's role only; admission needs to cover `vault-config` only. | *(C.0 Q19)* |

## 7. Template Operator v2 and Kubernetes

Template Operator v2 as built from `stakater-ab/template-operator-v2` `main`
at `0b89c9b`.

| # | Fact | Consequence | Source |
|---|---|---|---|
| T1 | A TemplateInstance's `fromAll` outputs read each of its own objects' VCO conditions: a mount collision shows as `secretEngineMountLastError` (400), a refused policy as `policyLastError` (403). The TI's own `Ready` stays `True`. | Health is in the outputs, per object, as on Enterprise. | *(C.0 Q5b)* |
| T2 | A Template's `targetNamespaces` decides where a TemplateInstance may live (`NamespaceNotPermitted` otherwise), not where its objects go: a Template in a tenant namespace may name `namespace: vault-config`, and Template Operator applies it with its own rights. Ownership labels a Template sets are overwritten with the real source (`templates.v2.stakater.com/instance-namespace`). | Admission refuses a VCO CR that Template Operator writes for a TemplateInstance outside `vault-config`; the label can be trusted. | *(C.0 Q18b)* |
| K1 | The Multi-Tenant Operator namespace webhook checks the tenant label, not the namespace name. | A tenant member may create a namespace with a name another tenant used. | tenant-operator `internal/webhook/webhook/namespace.go` at `61083f70`; *(C.0 Q13)* |
| K2 | ValidatingAdmissionPolicy (GA in Kubernetes 1.30) with CEL `matches`, `find`, `split`, and a ConfigMap parameter (`kube-root-ca.crt`) refuses VCO CRs before VCO sees them; server-side dry runs exercise it. | The scope check can run at the API server, with no webhook to operate. | kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy; *(C.0 Q18, Kubernetes 1.33)* |

## Open questions (VERIFY), owned by story C.0

Answered on 2026-11-02; evidence per question in
[`spikes/c0-findings.md`](spikes/c0-findings.md).

1. VCO `SecretEngineMount` with `path: <tenant>`, name `kv`, no
   `targetNamespace`: mount created at `<tenant>/kv`, idempotent across
   reconciles, finalizer present. (V2, V4) — **Yes** (V2). The shared auth
   mounts can't be `auth/kubernetes/workloads` (N7).
1. VCO's least-privilege policy narrowed by name prefix (`sys/policy/kv.*`,
   `auth/mto/workloads/role/kv.*`): does any VCO call need `list` on the
   unnarrowed path? (P4) — **No** (V9).
1. Mount-table size with 500 tenant mounts on integrated storage. (E4) —
   **27 KB**; linear to 5000 (E4).
1. Vault UI for a token holding only `<tenant>/kv/...`: the mount is listed,
   browsable, and no other tenant's mount appears. (N6) — **Yes** (N6).
1. A tenant named like an existing platform mount (`secret`): Vault's error, how
   VCO reports it, how it reaches the TemplateInstance outputs. (N3) — 400 on
   that CR alone (V8); `agent-registry` too (N8). It reaches the
   TemplateInstance outputs (T1).
1. ESO `SecretStore` with no namespace and `path: <tenant>/kv`, KV v2. —
   **Works**, rotation included.
1. A rate-limit quota on `<tenant>/kv` in Community Edition. (O2) — **Works**,
   by source IP only (O2).
1. Enterprise migration: a namespace `<tenant>` beside a root mount
   `<tenant>/kv`; `sys/remount` into the namespace. (O5) — **Still VERIFY**:
   needs an Enterprise licence.
1. Who can set `stakater.com/tenant` on a namespace under the customer's
   Multi-Tenant Operator setup (the trust boundary, as in the Enterprise
   extension). — **From source, not observed**: privileged ServiceAccounts,
   MTO, cluster admins, and owners of the tenant the new label names.
1. VCO drift detection on a `Policy` widened by hand in Vault, on Community
   Edition. (V7) — **Yes**, within one sync period (V7).
1. Login with another tenant's Kubernetes role: the error
   Vault returns, so the acceptance suite asserts the right refusal. (A1) —
   **403** `service account name not authorized` (A1).
1. Token and entity counts per tenant at scale (one entity per ServiceAccount
   alias on the shared mount). (N5) — one entity per ServiceAccount UID, never
   removed (N9); one token per login (A4).

The second C.0 run (questions 13 to 19: namespace reuse, type pinning, shares,
VCO's reach, per-tenant auth mounts, admission, VCO's login binding) is
recorded in the same findings; its facts are P5, P6, A1, A6, V10–V13, T1, T2,
K1 and K2.
