# C.7 — Sharing inside a tenant

Story: `docs/roadmap.md` C.7 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-SHR-1, AC-SHR-2.

## Why (one paragraph)

Apps of one tenant often need the same value — a database endpoint, a shared
API key. Without a shared folder they copy it, and the copies drift. The
Enterprise extension gives each namespace a `_shared/from-<ns>/` folder that
its editor apps write and every app of the namespace reads, and lets another
namespace of the same tenant subscribe to it, read-only. This story ports it
under the tenant's mount.

## Governing constraints

- ADR-0001 and invariant 7: the annotations `vault.stakater.com/kv-subscribe-ns`
  and `kv-subscribe.<name>`, and the ConfigMap keys `VAULT_KV_SHARED_OUT_PATH`
  and `VAULT_FROM_<NS>_PATH`, are the Enterprise ones.
- ADR-0003: the paths stay under `<tenant>/kv/…/<env>/_shared/from-<ns>/`; the
  scope check already allows them, and `_shared` can't be an app name.
- A subscription is read-only on the producer's prefix, on data AND metadata:
  KV v2 metadata `update` sets `max_versions` and destroys versions.
- A namespace outside the tenant can't be subscribed to.

## Design

Tenant chart, from the Enterprise templates:

- `_helpers.tpl`: `kv-subscribe-ns` joins the accepted keys; `vault.saFacts`
  refuses it with KV off, and a namespace that is not the tenant's.
- `04-sa-own-tenant.yaml`: the policy gains section 2 — read on its own
  namespace's `<tenant>/kv/data/<env>/_shared/from-<ns>/*` for every role but
  audit-read, list on its metadata; read and list (list only for audit-read)
  on each subscribed namespace's prefix, data and metadata; write on its own
  namespace's prefix for editor and admin, and delete, undelete, destroy for
  admin. The ConfigMap gains `VAULT_KV_SHARED_OUT_PATH` and one
  `VAULT_FROM_<NS>_PATH` per subscription; `vault-apps` gains `_namespace`.
- `05-deployment-externalsecrets.yaml`: the `kv-subscribe.<name>` form
  (`<writer-ns>/<leaf>[#<key>]` → `<env>/_shared/from-<writer>/<leaf>`), refused
  when the ServiceAccount does not subscribe to the writer (its own namespace
  needs no subscription) or the writer is not the tenant's.

## Tests (red first)

Render: `subread` (a subscriber's grant is read-only on data and metadata; an
audit-read subscriber lists only), the guard cases for a foreign namespace, a
subscription with KV off, a Deployment reading an unsubscribed namespace, the
positive controls; `contract` with the C.7 delta lines removed; the golden
regenerated.

Live: web (editor) writes its namespace's `_shared/`; viewer in the same
namespace reads and can't write; `sub` in another namespace, subscribed,
reads and can't write data or metadata (the producer's own metadata update is
the allow); `nosub` is refused; ESO delivers the subscription to a pod.

Mutation: give the subscription the role's capabilities; the subscriber's
metadata update must then succeed and the live check fail.

## Out of scope

Sharing across tenants (C.8).

## Done means

The roadmap Done line; `make verify` green; golden regenerated; e2e green;
`charts/README.md` updated (annotations, layout); story marked ✅ with this
doc linked.
