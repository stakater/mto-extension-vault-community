# Vision

## The problem

Platform teams run one HashiCorp Vault Community Edition for many application
teams. Community Edition has **no namespaces**: every team shares one set of
mounts, one auth method per type, one identity store, one policy list and one
audit log. So the platform team does tenancy by hand: a path layout per team,
a policy per application and access level, a Kubernetes auth role per
ServiceAccount, an OIDC role per identity-provider group, a SecretStore and an
ExternalSecret per workload — and all of it revisited whenever a team
changes. A single policy written a little too wide, `kv/data/team*` instead of
`kv/data/team-a/*`, and one team reads another's secrets.

In practice teams land in one of three places:

| Pattern | What goes wrong |
|---|---|
| One broad policy | quick, and one token reads every team's secrets |
| A ticket per request | safe, and the platform team becomes the queue |
| Kept by hand | a leaver keeps access; a deleted namespace keeps its role; a glob grows wider than anyone meant |

The Multi-Tenant Operator already knows who owns which namespaces. Vault
Community doesn't, and has no partition to put that knowledge into.

## The vision

> **One tenant definition, carried into Vault Community.** Every tenant gets a
> secret scope of its own — a mount, policies and login roles — derived from
> the `Tenant`, checked so no policy ever reaches past it, with the same
> annotations and the same developer experience as the Vault Enterprise and
> OpenBao extensions.

The product abstraction is **Tenant → secret scope**. Underneath, the
implementation depends on the edition:

| Backend | A tenant is |
|---|---|
| Vault Enterprise (`mto-extension-vault-enterprise`) | a Vault namespace |
| OpenBao (`mto-extension-openbao`) | an OpenBao namespace |
| **Vault Community (this repo)** | **a mount path + policies + login roles** |

The developer writes the same annotations and reads the same ConfigMap in all
three.

## Who it is for

| Persona | Job to be done | What they get |
|---|---|---|
| **Platform team** | run one Vault Community safely for many teams | tenants onboarded automatically; no policy written by hand; offboarding that revokes access and keeps data |
| **Application team** | get secrets into a pod without learning Vault | annotations on the ServiceAccount and Deployment; a plain Kubernetes Secret, kept in sync and rolled out on rotation |
| **Security and audit** | prove isolation without namespaces | every rendered policy checked against its tenant; short-lived tokens; access that closes when the definition changes |
| **Vault owners** | keep Vault the standard without buying Enterprise first | Vault's own mounts, policies and auth methods used as designed; a path to Enterprise or OpenBao that doesn't change a workload |

## Value proposition

- **Isolation by construction, on Community Edition.** A tenant's mount,
  policies and roles are derived, not configured, and every policy is checked
  to stay inside its tenant — so the one wall Community Edition has is never
  written by hand.
- **The same developer experience on every edition.** Same annotations, tiers,
  names and ConfigMap keys as the Enterprise and OpenBao extensions.
- **Tenants never administer Vault.** No tier can write a policy, mount an
  engine, or touch auth configuration — the shared Vault stays the platform's.
- **No new tool to learn.** It is Vault underneath. The extension writes the
  configuration; Vault enforces it.

## Principles

1. Vault enforces the boundary with its own ACL policies; the extension writes
   them, and proves they stay inside the tenant before they are written.
1. Platform owns mounts, policies and auth; tenants own their secrets.
1. Data outlives definitions. Deleting is always a separate, deliberate act.
1. When Community Edition can't do something per tenant, say so — don't fake
   it, and name the edition that can.

## Non-goals

- Emulating Vault namespaces. No per-tenant auth methods, audit devices,
  identity stores or delegated policy administration.
- Tenant-managed policies, mounts or auth configuration (see ADR-0004).
- Per-tenant quotas beyond what Community Edition offers (rate limits by source
  address only; lease-count quotas are Enterprise).
- Provisioning Vault itself, its storage, unseal or audit devices.
- Transit and PKI in v1 (Phase 3, as in the Enterprise extension).

## How we'll know it works

- Every policy the charts render passes the scope check: no path outside its
  tenant's mount or its named shares, no `sys/`, `auth/` or `identity/` path.
- Zero cross-tenant reads in the acceptance suite (`docs/acceptance.md`), each
  denial paired with a matching allow.
- An application gets a secret into a pod with two annotations and no Vault
  code, on Community Edition, end to end.
- The contract check against the Enterprise chart finds no difference in
  annotation keys, tiers, object names or ConfigMap keys.
