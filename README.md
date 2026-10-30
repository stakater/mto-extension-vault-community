# mto-extension-vault-community

The HashiCorp Vault **Community Edition** extension for the
[Multi-Tenant Operator](https://github.com/stakater/multi-tenant-operator).
Community Edition has no namespaces, so this extension gives every `Tenant` a
**secret scope** built from what Community has: its own KV mount, a policy and
login role per application, SSO roles per tier — every policy checked so it
never reaches past its tenant. Developers write the same annotations as with
the Vault Enterprise and OpenBao extensions.

> **Status: design phase.** This repository holds requirements and design. No
> chart is built yet. Start with [docs/vision.md](docs/vision.md), then
> [docs/design.md](docs/design.md).

## What a tenant gets

| On the platform | In Vault Community |
|---|---|
| Tenant `team-a` | KV v2 mount `team-a/kv/` |
| Annotated ServiceAccount `web` in `team-a-api` | policy and Kubernetes auth role `kv.team-a.team-a-api.web`, on its own prefix |
| Annotated Deployment | a Kubernetes Secret, through External Secrets Operator |
| Group `team-a-editors` | OIDC role `sso.team-a.editor`, across `team-a/kv/` |
| Tenant deleted | policies and roles revoked; the mount and its secrets kept |

## One experience, three backends

| Backend | A tenant is | Extension |
|---|---|---|
| Vault Enterprise | a Vault namespace | [mto-extension-vault-enterprise](https://github.com/stakater/mto-extension-vault-enterprise) |
| OpenBao | an OpenBao namespace | [mto-extension-openbao](https://github.com/stakater/mto-extension-openbao) |
| Vault Community | a mount + policies + login roles | this repo |

## How it is built

A port of mto-extension-vault-enterprise: two Helm charts, rendered per tenant
by [Template Operator v2](https://github.com/stakater-ab/template-operator-v2)
into [vault-config-operator](https://github.com/redhat-cop/vault-config-operator)
custom resources. See [ADR-0001](docs/adr/0001-port-the-enterprise-extension.md)
and, for the part Community Edition makes critical,
[ADR-0003](docs/adr/0003-policy-is-the-wall-so-check-every-policy.md).

## Documents

| | |
|---|---|
| [Vision](docs/vision.md) | why, for whom, value, non-goals |
| [Concepts](docs/concepts.md) | terms, the running example, Enterprise vs Community |
| [Roadmap](docs/roadmap.md) | phases and user stories |
| [Acceptance](docs/acceptance.md) | the isolation contract as testable scenarios |
| [Design](docs/design.md) | the delta from Enterprise, the scope check, limits |
| [Vault Community baseline](docs/vault-community-baseline.md) | what Vault Community 2.1.1 gives and where it stops, with sources |
| [Diagrams](docs/diagrams.md) | C4 and sequence diagrams |
| [ADRs](docs/adr/README.md) | decisions and rejected alternatives |
| [Method](docs/method.md) | how work moves from story to done |

The customer-facing deck for this extension lives in `stakater-sales/mto-sales`
(`src/pages/vault-community.astro`). This repository is the source of truth;
the deck follows it.
