#!/usr/bin/env bash
# Claude Code PostToolUse hook (DX.2, docs/method.md): after an edit to a
# Markdown file, run the fast method checks — the roadmap, planning-doc and ADR
# rules, and every relative link — so a broken rule shows up while the work
# happens, not at the PR. The chart checks stay in `make verify`.
#
# Claude Code sends the tool call as JSON on stdin. Exit 2 puts stderr in
# front of the agent; anything else is silent. METHOD_ROOT overrides the
# repository the checks run in (the hook's tests use it).
set -uo pipefail

root="${METHOD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# A python3 failure is reported, not read as "nothing to check".
file="$(python3 -c 'import json, sys; print((json.load(sys.stdin).get("tool_input") or {}).get("file_path") or "")' 2>&1)" \
  || { echo "claude-post-edit.sh could not read the tool call with python3: $file" >&2; exit 2; }
case "$file" in
  *.md) ;;
  *) exit 0 ;;
esac
# Only this repository's Markdown: a session here also edits files elsewhere
# (a scratch note, another repo's doc), and this repo's rules say nothing about
# them. Both paths resolved, so a symlinked /tmp or a relative path compares
# right.
inside="$(python3 -c 'import os, sys; f, r = (os.path.realpath(p) for p in sys.argv[1:3]); print("yes" if f.startswith(r + os.sep) else "no")' "$file" "$root" 2>&1)" \
  || { echo "claude-post-edit.sh could not compare $file with $root using python3: $inside" >&2; exit 2; }
[ "$inside" = yes ] || exit 0
if ! out="$(make -C "$root" -s method links 2>&1)"; then
  echo "make method links failed after the edit of $file:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
