# C.0 findings — the live-install spike

Story: `docs/roadmap.md` C.0. Plan:
[`../planning/C0-live-install-spike.md`](../planning/C0-live-install-spike.md).
Run on 2026-11-02 by Ayesha Arshad with Claude Code.

**Result.** Two runs on the same lab.

The **first run** answered eleven of the twelve planned questions with
evidence; question 8 is not needed (the extension is Community only) and
question 9 is answered from source, not observed. Its acceptance checks passed (15 of
15, plus AC-ISO-7 through VCO). It found that a shared workload auth mount
can't be `auth/kubernetes/workloads` in root (Q1b), and used `auth/mto/…`.

The **second run** verified the design against the Enterprise and OpenBao
extensions for least privilege and isolation, with Template Operator v2 built
from its `main` branch, and with an independent review of the design (Q13 to
Q19, [Second run](#second-run--design-verification)). It changes the design in
three places:

1. **One auth mount per tenant, at the Enterprise path with the tenant
   prefix**: `auth/<tenant>/kubernetes/workloads` and
   `auth/<tenant>/oidc/sso`, not one shared `auth/mto/…` (Q17). Offboarding
   then revokes the tenant's tokens, as on Enterprise.
1. **Every role binds its namespace by name and tenant label** (Q13). Bound by
   name only, a namespace name reused by another tenant reads the first
   tenant's secrets — on Enterprise too.
1. **Admission policies on the VCO CRs in `vault-config`** (Q16, Q18). VCO's
   name-narrowed Vault policy does not bound VCO: two CRs with valid names give
   a token close to root. On Enterprise the Vault namespace bounds it; on
   Community the scope check must run at the API server.

All 26 acceptance checks pass on the new design, and the admission policies
pass 34 of 34 cases.

## Environment

| Part | Version |
|---|---|
| Vault | Community Edition **2.1.1** (`d78bbbe2`), dev mode, no licence (`sys/license/status` has no value) |
| vault-config-operator | **v1.0.3** (`quay.io/redhat-cop/vault-config-operator:v1.0.3`), `ENABLE_DRIFT_DETECTION=true`, `SYNC_PERIOD_SECONDS=30`, `CACHE_VAULT_TOKEN=true` |
| Kubernetes | kind, **v1.33.4** |
| External Secrets Operator | chart 2.11.0 |
| cert-manager | v1.20.0 |
| Raft test (Q3 only) | a separate `hashicorp/vault:2.1.1` container, integrated storage, one node |
| Template Operator v2 (second run) | built from `stakater-ab/template-operator-v2` `main` at **`0b89c9b`**, deployed with its own `config/default` (no cluster-admin binding) plus a Role for the VCO kinds in `vault-config` only |

The lab is the Enterprise repo's (`stakater/mto-extension-vault-enterprise` at
`f7a4155`), built with `make lab-cluster lab-cert-manager lab-tenant-crd
lab-eso lab-reloader lab-vault lab-vco VAULT_EDITION=ce
CLUSTER_NAME=vault-ce-lab`.

**Deviations from the plan.**

- **Template Operator v2 from source, not the published chart.** The chart
  `oci://ghcr.io/stakater/public/charts/template-operator-v2` (and the new
  path `ghcr.io/stakater/charts/…`) returned 403 to the available ghcr.io
  logins, so the first run had none. The second run built the image from
  `main` (`docker build`, imported into the kind node with `ctr images
  import`, because `kind load` fails with this Docker's containerd image
  store) and deployed `config/default` with kustomize. Q5's TemplateInstance
  part is answered in the second run (Q5b).
- **No Keycloak or Dex.** The Dex config operator chart is on the same
  registry. No question needs an identity provider: Q4 and AC-ISO-9 use
  tokens made with the SSO tier policies, and Q2 configures the SSO mount with
  a throwaway public key.
- Every object of design §3 was applied by hand from [`c0/`](c0/), so the
  spike is repeatable: [`fixture.yaml`](c0/fixture.yaml),
  [`platform.yaml`](c0/platform.yaml), [`tenants.yaml`](c0/tenants.yaml),
  [`eso.yaml`](c0/eso.yaml), [`acceptance.sh`](c0/acceptance.sh).

## Answers

| # | Question | Answer |
|---|---|---|
| 1 | VCO creates `<tenant>/kv` with no target namespace, idempotently, with its finalizer | **Yes.** And: a shared auth mount can't be `auth/kubernetes/workloads` (Q1b); the design moves to per-tenant auth mounts (Q17) |
| 2 | VCO works with a name-narrowed policy | **Yes.** No `list` on any unnarrowed path; the only 403s are the two intended mount deletes |
| 3 | Mount table at 500 tenants | **No problem.** About 53 bytes per mount, linear to 5000 (265 KB); restart 2–3 s |
| 4 | UI for a one-mount token | **Works.** Lists only `team-a/kv/` (and `cubbyhole/`); other tenants' mounts are absent and refused |
| 5 | Tenant named like a platform mount | Refused by Vault with a 400 on that CR alone; also `agent-registry`, a mount Vault 2.1.1 adds. The error reaches the TemplateInstance outputs; the TI stays `Ready` (Q5b) |
| 6 | ESO with `path: <tenant>/kv`, no namespace | **Works**, rotation included |
| 7 | Rate-limit quota on `<tenant>/kv` | **Works**, grouped by source IP only |
| 8 | Vault namespace beside `<tenant>/kv`; remount into it | **Not needed** — the extension is Community only (2026-11-03) |
| 9 | Who can set `stakater.com/tenant` | From source: privileged ServiceAccounts, MTO, cluster admins, and owners of the tenant named in the new label |
| 10 | Drift detection reverts a hand-widened policy | **Yes**, within one sync period (19 s at 30 s); roles too |
| 11 | Error for another tenant's role | `403`, `service account name not authorized` |
| 12 | Entities and tokens at scale | One entity per ServiceAccount UID, never removed; one token per login, alive for its TTL; ESO reuses its token |
| 13 | A namespace name reused by another tenant | **Reads the first tenant's secrets** with a role bound by name (Enterprise's binding). Bound by name AND tenant label through VCO's selector: refused, and follows a relabel within seconds |
| 14 | Pin the mount type in VCO's policy | **Works.** `allowed_parameters` refuses a wrong type with 403; VCO's creates and tunes still pass |
| 15 | Cross-tenant shares (AC-SHR-3) | **Hold.** 11 of 11 checks: direction, peer, prefix tenant, enumeration, role reuse |
| 16 | Does the name-narrowed policy bound VCO? | **No.** A `kv.*` policy granting `*` and a `kv.*` role give a token that writes platform policies and reads every tenant |
| 17 | One auth mount per tenant, at `auth/<tenant>/kubernetes/workloads` | **Works** through VCO, ESO included. Disabling it revokes the tenant's tokens; removing a role from a shared mount does not |
| 18 | The scope check as admission | **Works.** 34 of 34 cases; also refuses Template Operator writing VCO CRs for a TemplateInstance outside `vault-config` (18b) |
| 19 | VCO's login from another namespace | **Refused**: 403 `namespace not authorized` |

### Q1 — the tenant mount through VCO

**Setup.** VCO logs in with role `vco-admin` on `auth/kubernetes`, first with
the broad spike policy [`c0/vco-broad-policy.hcl`](c0/vco-broad-policy.hcl).
`SecretEngineMount` `team-a-kv` with `path: team-a`, `name: kv`, `type: kv`,
`options.version: "2"`, `config.listingVisibility: hidden`, no
`targetNamespace` (and the same for `team-b`, `team`, `shared`).

**Observed.**

```text
SecretEngineMount   team-a-kv   [controller-secretenginemount]   ReconcileSuccessful
$ vault secrets list -detailed
team-a/kv/ kv v=2 listing=hidden
```

Two drift reconciles later (75 s, sync period 30 s) the mount's accessor was
unchanged (`kv_36d0e2ec`), a secret written before was still there, and VCO
logged no error. Deleting a throwaway CR `q1-del-kv` (with a secret in it)
under the broad policy disabled the mount and deleted the secret.

**Answer.** Yes on all three: created at `<path>/<name>` (V2 holds on
Community Edition), idempotent, finalizer present. With a policy that allows
it, a CR delete destroys the data (V3, E2): the narrowed policy is what keeps
it (Q2).

#### Q1b — the shared auth mounts can't nest under VCO's login mount

**Observed.** The `AuthEngineMount` for `auth/kubernetes/workloads`:

```text
URL: PUT http://vault.vault.svc:8200/v1/sys/auth/kubernetes/workloads
Code: 400. Errors:
* path is already in use at kubernetes/
```

Vault refuses an auth mount under an existing auth mount, as it does for
secrets mounts (N3). Re-checked on 2.1.1 in both orders: with
`c0probe/workloads` mounted first, `c0probe` is refused (`path is already in
use at c0probe/workloads/`); `c0probe2/workloads` with no parent mounts. On Enterprise the workload mount is inside the tenant's
Vault namespace, where nothing is mounted at `kubernetes/`; on Community
Edition it is in root, beside VCO's login at `auth/kubernetes`. The same
applies to `auth/oidc/sso` on any Vault where the platform already uses
`auth/oidc` — common for admin SSO.

**Consequence.** The extension's auth mounts need paths that nest under no
conventional mount. The first run used **`auth/mto/workloads`** and
**`auth/mto/sso`** (`AuthEngineMount` `path: mto`); both mounted, and every
first-run question ran on them. Secrets and auth mounts are separate tables,
so a tenant named `mto` still gets `mto/kv/` (Q5).

**Superseded by Q17.** The second run moved to one auth mount per tenant at
the Enterprise path with the tenant prefix (`auth/<tenant>/kubernetes/workloads`),
which nests under nothing for any tenant name except a platform auth mount's
first segment (`kubernetes`, `token`, …: reserved names). The contract is
unchanged either way: the mount reaches workloads only as the value of
`VAULT_K8S_MOUNT` and the ESO `mountPath`, as it does on Enterprise.

### Q2 — VCO with the name-narrowed policy

**Setup.** [`c0/vco-admin-policy.hcl`](c0/vco-admin-policy.hcl): design §6
with the auth paths of Q1b. Then two drift cycles of every existing CR, then
one new object of every kind from
[`c0/q2-new-objects.yaml`](c0/q2-new-objects.yaml) — a tenant mount, a
`Policy`, a `KubernetesAuthEngineRole`, the SSO `AuthEngineMount`, a
`JWTOIDCAuthEngineConfig` and a `JWTOIDCAuthEngineRole` — then a delete of
each.

**Observed.** 54 reconciles in the first 70 s, no error. All six new objects
`ReconcileSuccessful`. The deleted `Policy` and both roles were gone from
Vault. Every 403 VCO logged after the policy change, by URL:

```text
122 URL: DELETE http://vault.vault.svc:8200/v1/sys/auth/mto/sso
109 URL: DELETE http://vault.vault.svc:8200/v1/sys/mounts/team-c/kv
```

The two mount CRs stayed `Terminating` with their finalizers; the secret in
`team-c/kv` was still readable. The documented admin procedure finished them:
`vault secrets disable team-c/kv`, `vault auth disable mto/sso`, then remove
each CR's finalizer.

**Answer.** The narrowed policy is sufficient; no VCO call needs `list` or any
unnarrowed path. Data outlives the CR (ADR-0005, AC-LIFE-4).

**Consequence.** A `Terminating` mount CR retries its delete, and each retry
is a 403 in VCO's log and Vault's audit log, until a Vault admin purges it.
The admin runbook should say so.

### Q3 — the mount table at scale, on Raft

**Setup.** [`c0/q3-mount-table.sh`](c0/q3-mount-table.sh) on a separate
Vault 2.1.1 with integrated storage: enable `tNNNNN/kv` mounts (KV v2,
hidden) to each step; read the mount table gauges from `sys/metrics`; time one
more enable; restart the container, unseal, and time the first read.

**Observed.**

| Mounts | `mount_table.size` (bytes) | One more enable | Restart to first read |
|---|---|---|---|
| 500 | 27 249 | 114 ms | 2 s |
| 1000 | 53 643 | 125 ms | 2 s |
| 2000 | 106 380 | 160 ms | 2 s |
| 5000 | 264 549 | 209 ms | 3 s |

Creating mounts 2001–5000 took 137 s. The Raft data directory was 8.7 MB at
500 mounts and 670 MB at 5000: every mount change writes the whole mount table
to the Raft log, so its size grows with mounts × changes until Raft compacts
its log.

**Answer.** About 53 bytes per mount, linear to 5000. Raft's default
`max_entry_size` is 1 MiB, so by arithmetic (not reached) the mount table's
ceiling is near 19 000 mounts; 500 tenants use under 3 % of it. Creating a
mount slows from 114 ms to 209 ms; restart is unaffected. No ADR change. A
sizing note: at thousands of tenants each tenant create writes a few hundred
KB to the Raft log.

### Q4 — the UI for a token that holds one mount

**Setup.** A token with only policy `sso.team-a.editor` (the SSO editor tier,
paths under `team-a/kv/`), logged in to the Vault UI through a port-forward;
screenshots by a headless browser after login.

**Observed.** `sys/internal/ui/mounts` returns `cubbyhole/`, `identity/`,
`sys/` and `team-a/kv/` — no other tenant's mount, no `shared/kv/`,
`secret/` or `agent-registry/`. The secrets engine list shows `cubbyhole/`
and `team-a/kv/` ([`q4-ui-engines.png`](c0/q4-ui-engines.png)); the mount
browses to `dev/team-a-api/` ([`q4-ui-browse.png`](c0/q4-ui-browse.png));
`team-b/kv` shows `403 Not authorized`
([`q4-ui-other-tenant.png`](c0/q4-ui-other-tenant.png)). A workload token
(`web`) sees the same mount list but can't list the mount root, which only
the SSO tiers grant.

**Answer.** N6 holds. The Enterprise SSO policy's `path "kv/metadata"` line
becomes `path "team-a/kv/metadata"` and is still needed.

### Q5 — tenant names that collide with mounts

**Setup.** [`c0/q5-collisions.yaml`](c0/q5-collisions.yaml): tenant mounts
for `secret` (dev mode mounts `secret/`), `agent-registry` and `mto`.

**Observed.**

```text
secret-kv          fin=[]  ReconcileFailed: PUT .../v1/sys/mounts/secret/kv  Code: 400  * path is already in use at secret/
agent-registry-kv  fin=[]  ReconcileFailed: PUT .../v1/sys/mounts/agent-registry/kv  Code: 400  * cannot mount "agent-registry/kv/"
mto-kv             fin=[controller-secretenginemount]  ReconcileSuccessful
```

The other tenant mounts stayed `ReconcileSuccessful`.

**Answer.** Vault refuses the collision with a 400; VCO puts it on that CR's
status and gives it no finalizer, so deleting it is clean; no other tenant is
affected (AC-OPS-2). The TemplateInstance outputs: observed in the second run
(Q5b).

**Consequence.** Vault Community 2.1.1 mounts **`agent-registry/`** on its own
(type `agent_registry`). Add it to the reserved names in design §5.

### Q6 — ESO with `path: <tenant>/kv` and no namespace

**Setup.** [`c0/eso.yaml`](c0/eso.yaml): `SecretStore` `web-vault` with
`path: team-a/kv`, `version: v2`, no `namespace`, Kubernetes auth on
`mto/workloads` with role `kv.team-a.team-a-api.web`; `ExternalSecret`
`web-db-creds` extracting `dev/team-a-api/web/postgres`.

**Observed.** Store `Valid`, ExternalSecret `SecretSynced`; the Secret held
`spike-a1`. After `vault kv put` of `spike-a2`, the Secret held `spike-a2`
within one refresh.

**Answer.** Yes. The ESO key stays relative to the store's path, so only
`path` changes from Enterprise (`kv` → `<tenant>/kv`) and `namespace` goes.

### Q7 — a rate-limit quota on `<tenant>/kv`

**Observed.** `sys/quotas/rate-limit/tenant-team-a` with
`path=team-a/kv/ rate=5 interval=1s`: of 20 reads by `web` in one second, 5
returned 200 and 15 returned 429; 10 reads of `team-b/kv` in the same second
all returned 200. `group_by` `none`, `entity_then_ip` and `entity_then_none`:
`only available in Vault Enterprise`; `secondary_rate`: needs entity
grouping; a lease-count quota: `enterprise-only feature`.

**Answer.** A per-mount rate limit works, grouped by source IP only (O2
holds). It caps a tenant's mount as a whole from each client address; it
can't give per-tenant fairness. Documented, not rendered.

### Q8 — moving `<tenant>/kv` into a Vault namespace

**Not needed.** The extension is for Vault Community only (decided
2026-11-03), so moving a tenant into an Enterprise namespace is out of scope.
C.16 stays a Draft and is not planned.

### Q9 — who can set `stakater.com/tenant`

**Read, not observed** (MTO was not in the lab):
`stakater/tenant-operator` at `61083f70`,
`internal/webhook/webhook/namespace.go` and `util.go`. The namespace webhook
allows any create, update or delete by privileged ServiceAccounts, MTO's own
ServiceAccount and cluster admins. For anyone else, a namespace that carries
`stakater.com/tenant: X` is allowed only if the requester is an **owner of
tenant X**. On update it checks the label of the new object only, so an owner
of tenant B who also has Kubernetes RBAC to patch a namespace can relabel it
from A to B. Kubernetes RBAC on `namespaces` (cluster scope) is the first
gate.

**Answer.** The Enterprise trust note holds unchanged: only MTO and cluster
admins should hold `patch` and `update` on namespaces.

### Q10 — drift detection on a hand-widened policy

**Observed.** As root: appended `path "team-b/kv/data/*" { read }` to
`kv.team-a.team-a-api.jobs`, and set its role's bound ServiceAccount names and
namespaces to `*`. Both were back to the rendered state **19 s** later (sync
period 30 s).

**Answer.** Yes, within one `SYNC_PERIOD_SECONDS`. VCO's default with drift
detection on is 10 hours (V7), which is the window a hand-widened policy stays
wide. Recommend a short period in production and say so in the install
requirements.

### Q11 — another tenant's login role

**Observed.** `web`'s token on role `kv.team-b.team-b-api.api`:

```text
Code: 403. Errors:
* service account name not authorized
```

`api` logs in with the same role.

**Answer.** AC-ISO-5 asserts a 403 with this message.

### Q12 — entities and tokens at scale

**Setup.** [`c0/q12-scale.sh`](c0/q12-scale.sh): 100 ServiceAccounts in
`team-a-scale`, a role each, two logins each.

**Observed.**

```text
before:                 entities=5   aliases=5   tokens=12
after one login each:   entities=105 aliases=105 tokens=112
after two logins each:  entities=105 aliases=105 tokens=212
```

The role's `alias_name_source` is `serviceaccount_uid`. Deleting and
re-creating `app001` and logging in again: 106 entities — a new one, and the
old one stays. ESO with a 15 s refresh held one live token for `web` after
about 13 refreshes.

**Answer.** One entity and alias per ServiceAccount UID, in Vault's one
identity store; entities are never removed, so they grow with ServiceAccount
churn (re-created namespaces, preview environments). One service token per
login, alive for its TTL (3600 s here). ESO reuses its token. Sizing: entities
≈ every ServiceAccount UID that ever logged in; tokens ≈ logins per TTL.

## Second run — design verification

Asked for: verify the whole design, follow the Enterprise and OpenBao
extensions, least privilege, data isolation. Two inputs besides the lab: the
Enterprise production VCO policy and tenant chart (`charts/examples/vco-admin-policy.hcl`,
`01-tenant-scaffolding.yaml`, `04-sa-*.yaml`), and OpenBao's single-namespace
"path" layout (`docs/design/multi-tenant-path-layout.md`) and its tenancy ADR.
Both default to one namespace per tenant, with the tenant's auth mounts inside
it; OpenBao's path mode shares one auth mount and calls its isolation "soft —
ACL path rules". An independent review of the design, given the code and not
these conclusions, found seven issues; the table at the end of this section
says what became of each.

### Q5b — a VCO error at the TemplateInstance

**Setup.** [`c0/q5-ti-outputs.yaml`](c0/q5-ti-outputs.yaml): a Template in
`vault-config` rendering a good tenant mount, a mount that collides with
`agent-registry/`, and a `Policy` named `vco-admin`; its outputs are the
Enterprise `vcoOutputs` helper, unchanged.

**Observed.** The TI is `Ready=True`, `OutputsResolved=True`, and:

```text
secretEngineMountSucceeded  ti-tidemo-kv: ["True"]
secretEngineMountLastError  ti-agent-registry-kv: PUT .../v1/sys/mounts/agent-registry/kv  Code: 400  * cannot mount "agent-registry/kv/"
policyLastError             ti-vco-admin: GET .../v1/sys/policy/vco-admin  Code: 403  * permission denied
```

`fromAll` lists only the TI's own objects, not every CR in the namespace.

**Answer.** The error reaches the outputs, per CR (AC-OPS-1, AC-OPS-2). The
TI's own `Ready` does not reflect VCO: the outputs are the only signal, as on
Enterprise.

### Q13 — a namespace name reused by another tenant

**Why.** The MTO namespace webhook checks the tenant label, not the name
(`internal/webhook/webhook/namespace.go`, `handleV2`/`handleLegacy`). After
`team-a` deletes a namespace, a member of `team-b` may create one of the same
name with its own label. The Enterprise chart binds each role to a literal
namespace name (`04-sa-own-tenant.yaml`, `targetNamespaces.targetNamespaces`).

**Setup.** [`c0/q13-ns-reuse.yaml`](c0/q13-ns-reuse.yaml): namespace
`team-a-gone` (tenant `team-a`), ServiceAccount `app`, a secret, and two roles
for `app` through VCO — one bound by literal name, one by
`targetNamespaceSelector` on `kubernetes.io/metadata.name: team-a-gone` AND
`stakater.com/tenant: team-a`. Then: delete the namespace; recreate it with
`stakater.com/tenant: team-b`; log in as its `app`.

**Observed.**

```text
VCO resolves the selector to names:   both roles bound_service_account_namespaces=["team-a-gone"]
namespace deleted (5 s), 20 s later:  literal ["team-a-gone"]   selector ["__no_namespace__"]
recreated as team-b:                  literal login ALLOWED, reads team-a's secret ("team-a-only")
                                      selector login DENIED, Code: 403
recreated as team-a:                  selector ["team-a-gone"], login allowed
relabelled to team-b (cluster admin): selector ["__no_namespace__"] within 20 s, login 403
```

**Answer.** Bound by name only, a reused name reads the earlier tenant's
secrets for as long as the role exists — until Template Operator re-renders
and VCO deletes it, or indefinitely if either is down. VCO v1.0.3 watches
namespaces and re-resolves a selector within seconds, to `__no_namespace__`
when nothing matches. It can't render Vault's own
`bound_service_account_namespace_selector` (not in its CRD), so a label change
made while VCO is down is not seen until VCO returns.

**Consequence.** Every role binds its namespace by name AND tenant label
(design §3, §4). The same gap is in the Enterprise chart.

### Q14 — the mount type pinned in VCO's policy

**Setup.** VCO's policy with `allowed_parameters = { "type" = [<type>], "*" = [] }`
on `sys/mounts/+/kv` (`kv`), and on the auth mount paths (`kubernetes`,
`oidc`). [`c0/q14-pinned-types.yaml`](c0/q14-pinned-types.yaml): one CR of
the right type and one of a wrong type per path, and a tune of an existing
secrets and auth mount.

**Observed.** `pin-ok-kv` (kv) and an `oidc` mount at the SSO path reconcile;
`pin-bad-kv` (`transit` at `pinbad/kv`) and a `userpass` mount at the SSO path
get `Code: 403 … permission denied`; both tunes apply
(`default_lease_ttl` 3600 on each).

**Answer.** Yes. VCO's policy is bounded by name and by mount type; VCO's
creates and tunes need nothing else. Parameter rules see only top-level keys,
so `config` (audit and header settings) can't be pinned here: the admission
policies pin it (Q18).

### Q15 — cross-tenant shares (AC-SHR-3)

**Setup.** [`c0/q15-shares.yaml`](c0/q15-shares.yaml): the Enterprise share
policies (`04-sa-share-out.yaml`, `04-sa-share-in.yaml`) with full paths:
`team-a`'s `web` exports to `team-b`, `team-b`'s `api` imports from `team-a`,
and the prefix tenant `team` exports to `team-b`. Checks in
[`c0/acceptance.sh`](c0/acceptance.sh).

**Observed.** 11 of 11 (output under [Acceptance](#acceptance-scenarios-run-by-hand)).

**Answer.** The share holds in its direction only; `team`'s
`from-team/to-team-b/` does not reach `from-team-a/`; the importer can list
its share folder but not `shared/kv/metadata/dev/`; each side is refused the
other's share role; the export token is refused the exporter's own secrets.

### Q16 — does the name-narrowed policy bound VCO?

**Setup.** [`c0/q16-vco-compose.yaml`](c0/q16-vco-compose.yaml), through VCO
with the narrowed policy: `Policy kv.x.y.z` with
`path "*" { capabilities = [all, "sudo"] }`, and `KubernetesAuthEngineRole
kv.x.y.z` bound to a ServiceAccount the writer controls. Then log in with it.

**Observed.** Both reconcile. With the token:

```text
vault policy write zz-probe …        Success! Uploaded policy: zz-probe
vault kv get -mount=team-b/kv …      (team-b's secret)
vault policy read vco-admin          allowed
vault secrets tune team-a/kv         Success! Tuned the secrets engine at: team-a/kv/
```

**Answer.** No. The policy bounds the names VCO writes, not what a `kv.*`
policy grants. Whoever writes VCO CRs in `vault-config` — or holds VCO's token
— has a token close to root. On Enterprise the same two CRs stay inside one
tenant's Vault namespace, because VCO writes policies there only
(`+/sys/policy/*`).

**Consequence.** Design §6, ADR-0006 and AC-ISO-7 claimed more than holds. The
scope check must run where the CRs are written: admission (Q18).

### Q17 — one auth mount per tenant

**Why.** Enterprise renders `kubernetes/workloads` (and `oidc/sso`) inside
each tenant's namespace, from the tenant chart; disabling it when the tenant
goes revokes the tenant's tokens. A shared `auth/mto/workloads` can't do that.

**Setup.** [`c0/q17-per-tenant-auth.yaml`](c0/q17-per-tenant-auth.yaml):
`AuthEngineMount` `path: team-a/kubernetes`, `name: workloads`, its config and
a role, through VCO, with `sys/auth/+/kubernetes/workloads` (type pinned,
delete allowed) in its policy; a tenant named `kubernetes`. Then ESO on the
new mount, and offboarding compared with the shared mount.

**Observed.**

```text
auth/team-a/kubernetes/workloads/   mounted, config and role reconcile
tenant "kubernetes"                 PUT .../v1/sys/auth/kubernetes/kubernetes/workloads  Code: 400  * path is already in use
web login on the tenant mount       reads its own secret; team-b: Code: 403
ESO SecretStore mountPath           team-a/kubernetes/workloads: Ready, SecretSynced, a rotated value reaches the Secret
shared mount, role deleted          old token still reads team-a's secret (up to tokenMaxTTL, 4 h)
tenant mount, mount CR deleted      VCO disables the mount; old token: Code: 403
```

Then every role of the fixture moved to per-tenant mounts
([`c0/per-tenant.yaml`](c0/per-tenant.yaml)), shares to
`auth/shared/kubernetes/workloads`, under the final VCO policy
([`c0/vco-admin-policy.hcl`](c0/vco-admin-policy.hcl)) and the admission
policies: `MOUNTS=per-tenant acceptance.sh`, 26 of 26.

**Answer.** Yes, and it follows Enterprise: the tenant chart renders the
tenant's auth mounts, and every Vault path is the Enterprise path with the
tenant prefix. Offboarding revokes tokens. A tenant name equal to the first
segment of a platform auth mount (`kubernetes` — VCO's login —, `token`, an
admin `oidc`) fails with a 400 on that tenant alone: reserved names.

**Cost.** Two or three mounts per tenant instead of one (Q3: the mount table
is linear, ~53 bytes per mount; the auth table is separate). With SSO, each
tenant's mount has its own callback URL
(`https://<vault>/ui/vault/auth/<tenant>/oidc/sso/oidc/callback`), so the IdP
client needs one redirect URI per tenant or a wildcard; Enterprise avoids this
with `namespace_in_state`. Not verified here: no IdP in the lab (C.6).

### Q18 — the scope check as admission

**Setup.** [`c0/q18-admission.yaml`](c0/q18-admission.yaml): three
ValidatingAdmissionPolicies on the VCO CRs in `vault-config` (Kubernetes
1.30+):

- **origin** — a VCO CR that Template Operator writes must carry its
  `instance-namespace: vault-config` label;
- **scope** — design §4 on the content: names in a family, one-line path
  stanzas with no `sudo`, every path in the name's scope (share direction
  included), a role binds its own policy, its tenant's mount, its
  ServiceAccount, and its namespace by name and tenant label; an SSO role
  binds exactly its tenant's group with string claims; mounts of the
  extension's shapes, with no audit or header settings;
- **cluster** — a Kubernetes auth config names this cluster's API, and a CA
  equal to `kube-root-ca.crt` (VCO's webhook injects its pod's CA, but keeps
  a CA the CR supplies).

[`c0/q18-admission.sh`](c0/q18-admission.sh): server-side dry runs, each
refusal one field away from an admitted CR.

**Observed.** 34 of 34. Refused, each by the policy and with its message:
Q16's policy, `team-a*`, another tenant's path, the prefix tenant on
`team-a`'s path, `team-a/kv/config`, a JSON body, a multi-line stanza, `sudo`,
a name outside the families, an export in the peer's direction, an import that
writes, a role bound to another tenant's policy, mount, ServiceAccount or
label, a role bound by name only, an SSO role for another tenant's group,
with glob claims, or with no claims, a mount logging request data in clear, a
`userpass` mount in an auth mount's place, a config for another API or CA.
Admitted: each of their good twins, on the real VCO CRDs. Every role of
`per-tenant.yaml` then went through the policies and reconciled.

#### Q18b — Template Operator writing for a tenant

**Observed.** A TemplateInstance in `team-a-api` naming the extension's
Template in `vault-config` is refused by Template Operator
(`TargetNamespaceAllowed=False`, `NamespaceNotPermitted`). But a Template
**in `team-a-api`** whose objects say `namespace: vault-config` is applied
there, with Template Operator's own rights: a VCO `Policy` appeared in
`vault-config` and VCO wrote it to Vault. Labels the Template sets to forge
the source are overwritten (`instance-namespace: team-a-api`).

**Answer.** The Template's `targetNamespaces` decides where a TemplateInstance
may live, not where its objects go. A tenant allowed to create Templates and
TemplateInstances could make Template Operator write VCO CRs, and with Q16,
reach every tenant. The lab gives tenants no such rights, but the design can't
depend on that: the origin policy refuses it (`a VCO object in vault-config
must come from a TemplateInstance in vault-config`), and the scope policy
would refuse an out-of-scope CR from any source.

### Q19 — VCO's login from another namespace

**Setup.** A ServiceAccount named `vco-admin` in `team-a-api`, and a VCO
`Policy` CR there naming it.

**Observed.** `PUT .../v1/auth/kubernetes/login  Code: 403  * namespace not
authorized`; nothing written. VCO's login role binds `vco-admin` in
`vault-config` only.

**Answer.** VCO CRs outside `vault-config` log in as whatever their own
ServiceAccount's role grants — never as VCO. The admission policies therefore
need to cover `vault-config` only.

### The independent review

| # | Review finding | Verified | Outcome |
|---|---|---|---|
| 1 | VCO's narrowed policy does not bound VCO; two CRs give a token close to root | **Yes** (Q16) | admission policies (Q18); ADR-0006 and design §6 rewritten |
| 2 | The scope check covers paths and names, not role content; SSO `fallback` binds no group | Yes, by Q18's cases | role and SSO-role rules in design §4 and the scope policy; `fallback` refused |
| 3 | Two clusters on one Vault rewrite each other's auth config | Not run (one cluster) | install requirement: one cluster per Vault, design §9 |
| 4 | Offboarding does not revoke tokens; a reused tenant name brings back peers' shares | **Yes** (Q17) | per-tenant auth mounts revoke tokens; the purge runbook also covers peers' share annotations, design §7 |
| 5 | Roles bind namespace names only | **Yes** (Q13) | name AND tenant label, through VCO's selector |
| 6 | Every tenant token gets root's `default` policy | Yes, by design | a check that `default` is unchanged, design §8 |
| 7 | Share direction, `t/kv/config` and `+` rules too loose | Yes, by Q18's cases | §4 tightened: direction, sub-paths of `t/kv/`, no `+` |

## Acceptance scenarios run by hand

[`c0/acceptance.sh`](c0/acceptance.sh), as the workloads.

**Second run**, on the per-tenant auth mounts (`MOUNTS=per-tenant`), with the
final VCO policy and the admission policies in place: 26 of 26 — the first
run's 15 below, on each tenant's own mount, and AC-SHR-3:

```text
== AC-SHR-3 a share reaches its peer only, in its direction
PASS  web writes its export to team-b
PASS  api reads team-a's export
PASS  api writes team-a's export (403)
PASS  web's own token reads the export (403)
PASS  core's export reads from-team-a/ (403)
PASS  core's export writes from-team-a/ (403)
PASS  api lists the export folder
PASS  api lists every share (403)
PASS  web reads its own secret
PASS  web's export token reads web's secret (403)
PASS  web logs in with api's import role (403)
== result: 0 failed
```

**First run**, on the shared `auth/mto/workloads`, with the narrowed VCO
policy:

```text
== AC-ISO-1 an app can't read a sibling app
PASS  web reads its own secret
PASS  jobs reads web's secret (403)
== AC-ISO-2 a tenant can't reach another tenant's mount
PASS  api reads its own secret
PASS  web reads team-b's secret (403)
PASS  api lists its own prefix
PASS  web lists team-b's prefix (403)
== AC-ISO-3 a prefix tenant can't reach its longer neighbour
PASS  core reads its own secret
PASS  core reads team-a's secret (403)
PASS  core lists team-a's mount (403)
== AC-ISO-5 / question 11: another tenant's login role
PASS  web refused team-b's role
      observed: Code: 403. Errors: * service account name not authorized
PASS  api logs in with its own role
== AC-ISO-9 no tier administers Vault (admin-tier token, no IdP in the spike)
PASS  admin tier destroys a version in its tenant
PASS  admin tier writes sys/policy/x (403)
PASS  admin tier mounts sys/mounts/x (403)
PASS  admin tier writes a workload role (403)
== result: 0 failed
```

**AC-ISO-3 mutation.** A token with `path "team*" { read }` read
`team-a/kv/data/dev/team-a-api/web/postgres` — P2 holds on Community Edition,
and the `/` after the tenant segment is what keeps `team` out of `team-a`.

**AC-ISO-7** ([`c0/q-iso7-widen.yaml`](c0/q-iso7-widen.yaml)). Through VCO,
with the narrowed policy: a `Policy` CR named `vco-admin`, one named
`default`, and a `KubernetesAuthEngineRole` on `auth/kubernetes` (VCO's own
login mount). Each `ReconcileFailed` with `Code: 403 … permission denied` on
`GET /v1/sys/policy/vco-admin`, `/v1/sys/policy/default` and
`/v1/auth/kubernetes/role/kv.evil.vco-login`; `vco-admin` unchanged (same
hash), no role added. This shows only that VCO can't write those objects
directly; Q16 shows it can grant the same power through objects whose names
pass.

## Other facts observed

- Vault 2.1.1 Community adds a built-in mount **`agent-registry/`** and a
  policy **`default-ceiling`** (read of the caller's own `agent-registry`
  registration and of the default policies). Neither widens a tenant token.
- Vault 2.1.1 warns on every Kubernetes auth role without `audience`:
  `Role … does not have an audience configured`. Binding an audience is a
  hardening for C.2; it needs each workload's token requested with that
  audience (ESO `serviceAccountRef.audiences`).
- `vault write` has no `-no-print` flag in 2.1.1.
- VCO's webhook refuses a change of `spec.path` on an existing role
  (`spec.path cannot be updated`): moving a role to another mount is a delete
  and a create.
- VCO re-creates a mount that is disabled by hand while its CR is live
  (within one sync period, empty). Under a `Terminating` CR it does not: the
  admin purge must disable the mount only after the CR is deleted (design §7).
- A Kubernetes auth config CR that VCO reconciles before its mount exists
  fails once with a 404 and succeeds on the retry.

## What changes

| Doc | Change | Why |
|---|---|---|
| `design.md` §2, §3 | one auth mount per tenant at the Enterprise path with the tenant prefix (`auth/<tenant>/kubernetes/workloads`, `auth/<tenant>/oidc/sso`), rendered by the tenant chart; shares on `auth/shared/kubernetes/workloads`, rendered by the parent | Q17 (replaces Q1b's `auth/mto/…`) |
| `design.md` §3, §4 | roles bind namespace name AND tenant label; role and SSO-role rules; share direction; sub-paths of `t/kv/`; one-line stanzas, no `sudo` | Q13, Q15, Q18, review 2, 7 |
| `design.md` §4, §6, §9 | admission policies on VCO CRs in `vault-config`; VCO's policy pinned by type; VCO's identity stated as close to root | Q14, Q16, Q18 |
| `design.md` §5 | `agent-registry`, `token` and VCO's login mount reserved; platform auth mounts in `parent.reservedPaths` | Q5, Q17 |
| `design.md` §7 | offboarding revokes tokens; purge order; peers' share annotations | Q17, review 4, other facts |
| `design.md` §8, §9, §10 | `default` unchanged check; one cluster per Vault; Kubernetes ≥ 1.30; Template rights | review 3, 6, Q18b |
| `vault-community-baseline.md` | VERIFY rows answered; new rows for both runs | all |
| ADR-0002, ADR-0003, ADR-0006 (Proposed, so their text can change) | per-tenant auth mounts; admission as an enforcement point; VCO bounded by name and type, content by admission | Q16, Q17, Q18 |
| `acceptance.md` | AC-ISO-5, -7, -9 on the new mounts; new AC-ISO-10 (namespace reuse), -11 (scope at admission), -12 (Template Operator as a deputy); AC-LIFE-4 tokens; AC-OPS-1 observed | all |
| `concepts.md`, `diagrams.md`, roadmap C.6 | the auth mount paths | Q17 |
| `design.md` §3, `concepts.md` | the example workload policy now matches the Enterprise chart (it gave metadata only read and list, and read on all of `_shared/`) | ported in `c0/tenants.yaml` |

**Gaps that are also in the Enterprise extension** (contract unchanged, so
no parity rule forces them, but the same fix applies there): roles bound by
namespace name only (Q13); `sso.tenantRoleMapping.fallback`, which renders an
SSO role with no bound claims (review 2). Each needs a story in that repo.

ADR status, recommended for the code owner's decision: **0001, 0004, 0005 →
Accepted** (each held on the live install). **0002, 0003, 0006 → Accepted
after review of their changed text** (per-tenant auth mounts; admission as an
enforcement point; VCO bounded by name and type, with the content bound at
admission). None needs superseding: none was Accepted.

**Decision (2026-11-03).** Ayesha Arshad closed C.0 with these findings: all
six ADRs are Accepted, and question 8 is not needed because the extension is
for Vault Community only. The annotation contract follows Enterprise main,
which renamed the tier annotation to `vault.stakater.com/role` (Enterprise
`e303ba0`).
