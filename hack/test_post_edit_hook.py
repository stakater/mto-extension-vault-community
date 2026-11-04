"""Tests for hack/claude-post-edit.sh, the PostToolUse hook (DX.2)."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "hack", "claude-post-edit.sh")


def run_hook(file_path, method_root=None):
    env = dict(os.environ)
    if method_root:
        env["METHOD_ROOT"] = method_root
    payload = json.dumps({"tool_name": "Edit", "tool_input": {"file_path": file_path}})
    return subprocess.run([HOOK], input=payload, capture_output=True, text=True, env=env)


class PostEditHookTest(unittest.TestCase):
    def test_non_markdown_edit_runs_nothing(self):
        r = run_hook(os.path.join(ROOT, "Makefile"), method_root="/nonexistent")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_markdown_edit_in_a_green_tree_passes(self):
        r = run_hook(os.path.join(ROOT, "docs", "roadmap.md"))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_markdown_edit_with_a_broken_rule_exits_2(self):
        tmp = tempfile.mkdtemp()
        try:
            for d in ("docs", "hack"):
                shutil.copytree(os.path.join(ROOT, d), os.path.join(tmp, d))
            shutil.copy(os.path.join(ROOT, "Makefile"), tmp)
            roadmap = os.path.join(tmp, "docs", "roadmap.md")
            with open(roadmap, encoding="utf-8") as f:
                text = f.read()
            # A story In progress with no planning doc that cites it.
            text = text.replace("**Story C.14 — Per-tenant audit recipe** 📝 *Draft*",
                                "**Story C.14 — Per-tenant audit recipe** 🔨 *In progress*")
            with open(roadmap, "w", encoding="utf-8") as f:
                f.write(text)
            r = run_hook(roadmap, method_root=tmp)
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn("C.14", r.stderr)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
