# DX.2 — The method on every edit

Story: `docs/roadmap.md` DX.2 (👍 Approved by Ayesha Arshad, 2026-11-03).
Acceptance: none (developer experience).

## Why (one paragraph)

`make verify` runs in CI and before a push, but a broken method rule — a
story marked In progress without a planning doc, a dead relative link — shows
up only then. kube-ward runs the fast checks after every edit. This story does
the same here for Claude Code sessions, which edit most of this repo's docs.

## Governing constraints

- `docs/method.md`, "Known enforcement gaps": nothing runs on each local edit.
- The checks check: the hook has a test that fails when it stops reporting.
- No secret in any file; the hook reads only the edited path.

## Design

- `hack/claude-post-edit.sh`: a PostToolUse hook. It reads the tool call's
  JSON on stdin, and for an edited `*.md` file runs `make method links` in the
  repository (or `METHOD_ROOT`). A failure exits 2 with the output on stderr,
  which Claude Code shows to the agent; anything else exits 0.
- `.claude/settings.json`: the hook on `Edit|Write|MultiEdit`.
- `hack/test_post_edit_hook.py`: a non-Markdown edit runs nothing; a Markdown
  edit in a green tree passes; in a copy with a broken roadmap it exits 2 and
  names the rule.
- `CLAUDE.md` and `docs/method.md` name the hook; the enforcement gap row goes.

## Tests (red first)

`hack/test_post_edit_hook.py` before the script exists: it fails.

## Out of scope

Running the chart checks on every edit (too slow for a hook; `make verify`
remains the gate).

## Done means

The roadmap Done line; `make verify` green (it runs the new test); story
marked ✅ with this doc linked.
