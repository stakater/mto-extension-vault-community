# C.10 — Rotation reaches the pod

Story: `docs/roadmap.md` C.10 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: AC-DEL-2.

## Why (one paragraph)

C.4 delivers a secret to a pod once. A rotated secret must reach the app too,
or rotation needs a manual restart. External Secrets Operator re-reads Vault
every `parent.externalSecretRefreshInterval` and updates the Secret; an
environment variable is read only at container start, so Stakater Reloader
rolls the Deployment when the Secret changes. This story proves the chain on
Vault Community and documents the one annotation the app team adds.

## Governing constraints

- Enterprise parity: the annotation is Reloader's own,
  `secret.reloader.stakater.com/reload: <secret>`, on the Deployment; the
  charts render nothing for it.
- The rotation is written as the workload, through its own grant (C.2).

## Design

No chart change. The e2e suite's `eso` step adds the Reloader annotation to
`web`'s Deployment, and a new step rotates `db` as `web` and waits for a new
pod that sees the new value. The lab already installs Reloader
(`make lab-reloader`). `charts/README.md` documents the annotation.

## Tests (red first)

Live: the new value reaches the Secret within the refresh interval (10 s in
the suite), and a NEW pod sees it — an env var can't change in a running
container, so the new pod proves Reloader rolled the Deployment (AC-DEL-2).

## Out of scope

Rotation of the Vault credentials themselves (Vault tokens are short-lived
already); Reloader's own configuration.

## Done means

The roadmap Done line; `make verify` green; e2e green; README updated; story
marked ✅ with this doc linked.
