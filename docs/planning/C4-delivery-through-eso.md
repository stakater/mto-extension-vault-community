# C.4 — Delivery through External Secrets Operator

Story: `docs/roadmap.md` C.4 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-DEL-1.

## Why (one paragraph)

After C.2 an app can log in and read its secrets, but only if its code calls
Vault. Most teams want a Kubernetes Secret instead. The Enterprise extension
renders, from one Deployment annotation, an External Secrets Operator
`SecretStore` that logs in as the app's ServiceAccount and an
`ExternalSecret` that writes the Secret. This story ports that slice, with
the store pointed at the tenant's mount instead of a Vault namespace.

## Governing constraints

- ADR-0001 and invariant 7: the annotation `vault.stakater.com/kv-secret.<name>`
  and the object names `<sa>-vault`, `<sa>-<name>` are the Enterprise ones.
- ADR-0007: the store's KV path is the tenant's mount `<tenant>/kv`, its auth
  mount `<tenant>/kubernetes/workloads`, and it has no `namespace`.
- Enterprise CLAUDE.md: ESO lives in its own slice (`eso`) and TI, so a missing
  ESO CRD fails only that TI; `create` on ESO kinds is gated on
  `parent.eso`, the reap verbs are not (C.1's `rbacgate`).
- A Deployment's ask is checked against its ServiceAccount's grants, so an
  ExternalSecret never names a path the policy does not grant.

## Design

Tenant chart:

- `templates/04-sa-own-tenant.yaml`, eso slice: per annotated ServiceAccount,
  `SecretStore <sa>-vault`:

  ```yaml
  provider:
    vault:
      server: <vaultServer>
      path: team-a/kv
      version: v2
      auth:
        kubernetes:
          mountPath: team-a/kubernetes/workloads
          role: kv.team-a.team-a-api.web
          serviceAccountRef: { name: web }
  ```

  No `namespace` field. `caBundle` with `vaultCABundle`.
- `templates/05-deployment-externalsecrets.yaml`: Enterprise's, with the
  `kv-secret.<name>` form (`<leaf>[#<key>]` → `remoteRef.key:
  <env>/<ns>/<app>/<leaf>`, relative to the store's mount). The
  `kv-subscribe.<name>` and `kv-import.<name>` forms arrive with C.7 and C.8;
  until then they are reported as unknown keys. ESO disabled install-wide:
  a `deploy-error` ConfigMap from the core slice.
- Fixtures: `values-full.yaml` gains annotated Deployments; `values-guards.yaml`
  gains the Deployment cases that apply (dedupe, clash, no ServiceAccount,
  misplaced key, hostile key, leaf and name).

## Tests (red first)

Render: `exclusivity` (external-secrets.io objects only in the eso slice),
`mountagree` extended to the SecretStores, `storepath` (every store's path is
`<tenant>/kv`, version v2, no namespace), the Deployment `guards` cases, the
golden regenerated deliberately.

Live: a Deployment annotated `kv-secret.db: db#password` gets Secret
`web-db` with the value written in Vault, and the pod sees it as an
environment variable; a whole leaf becomes one Secret (AC-DEL-1).

Mutation: point the store at another tenant's mount; `storepath` and the live
check go red.

## Out of scope

Subscriptions and imports through ESO (C.7, C.8); Reloader (C.10); the eso
slice's health outputs (C.11).

## Done means

The roadmap Done line; `make verify` green; golden regenerated; e2e green;
`charts/README.md` "ExternalSecrets" written; story marked ✅ with this doc
linked.
