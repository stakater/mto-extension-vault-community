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
file="$(python3 -c 'import json, sys; print((json.load(sys.stdin).get("tool_input") or {}).get("file_path") or "")' 2>/dev/null)" || exit 0
case "$file" in
  *.md) ;;
  *) exit 0 ;;
esac
if ! out="$(make -C "$root" -s method links 2>&1)"; then
  echo "make method links failed after the edit of $file:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
