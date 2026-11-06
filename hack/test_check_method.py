"""Table-driven tests for check_method.py (docs/method.md, "Enforced by")."""

import os
import subprocess
import tempfile
import textwrap
import unittest

import check_method as cm

ROADMAP_HEAD = "# Roadmap\n\n"


def story(code, status, done=True, extra=""):
    marker = cm.STATUSES[status]
    body = f"**Story {code} — Title** {marker} *{status}*\n\nAs a user, I want x.\n"
    if done:
        body += "\nDone: it works.\n"
    return body + extra + "\n"


def adr(status, body="## Context\n\nWhy.\n"):
    return f"# ADR-0001: Title\n\n- **Status:** {status}\n- **Date:** 2026-10-03\n\n{body}"


def adr_index(status):
    return (
        "# ADRs\n\n| # | Decision | Status |\n|---|---|---|\n"
        f"| [0001](0001-title.md) | Title | {status} |\n"
    )


def plan(code):
    return f"# {code} — Title\n\nStory: `docs/roadmap.md` {code} (👍 Approved).\n"


class Repo:
    """A throwaway repo layout: {relative path: content}."""

    def __init__(self, files):
        self.dir = tempfile.TemporaryDirectory()
        for path, content in files.items():
            full = os.path.join(self.dir.name, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(content))

    def __enter__(self):
        return self.dir.name

    def __exit__(self, *exc):
        self.dir.cleanup()


def base_files(**override):
    files = {
        "docs/roadmap.md": ROADMAP_HEAD + story("C.0", "Draft") + story("C.1", "Draft", done=False),
        "docs/adr/0001-title.md": adr("Proposed"),
        "docs/adr/README.md": adr_index("Proposed"),
        "docs/planning/TEMPLATE.md": "# {Story code} — {short title}\n",
    }
    files.update(override)
    return files


class RepoChecks(unittest.TestCase):
    CASES = [
        # (name, file overrides, expected substring of an error, or None for clean)
        ("clean draft roadmap", {}, None),
        (
            "unknown status",
            {"docs/roadmap.md": ROADMAP_HEAD + "**Story C.0 — Title** 📝 *Sketch*\n\nDone: x\n"},
            "unknown status",
        ),
        (
            "marker does not match status",
            {"docs/roadmap.md": ROADMAP_HEAD + "**Story C.0 — Title** ✅ *Draft*\n\nDone: x\n"},
            "marker",
        ),
        (
            "approved story needs a Done line",
            {"docs/roadmap.md": ROADMAP_HEAD + story("C.0", "Approved", done=False)},
            "Done:",
        ),
        (
            "draft brief without Done line is fine",
            {"docs/roadmap.md": ROADMAP_HEAD + story("C.0", "Draft", done=False)},
            None,
        ),
        (
            "two stories in progress",
            {
                "docs/roadmap.md": ROADMAP_HEAD + story("C.0", "In progress") + story("C.1", "In progress"),
                "docs/planning/C0.md": plan("C.0"),
                "docs/planning/C1.md": plan("C.1"),
            },
            "one story at a time",
        ),
        (
            "in progress without a planning doc",
            {"docs/roadmap.md": ROADMAP_HEAD + story("C.0", "In progress")},
            "no planning doc",
        ),
        (
            "in progress with a planning doc",
            {
                "docs/roadmap.md": ROADMAP_HEAD + story("C.0", "In progress"),
                "docs/planning/C0.md": plan("C.0"),
            },
            None,
        ),
        (
            "done story must link its planning doc",
            {
                "docs/roadmap.md": ROADMAP_HEAD + story("C.0", "Done"),
                "docs/planning/C0.md": plan("C.0"),
            },
            "link its planning doc",
        ),
        (
            "done story linking its planning doc",
            {
                "docs/roadmap.md": ROADMAP_HEAD
                + story("C.0", "Done", extra="Plan: [C.0](planning/C0.md)\n"),
                "docs/planning/C0.md": plan("C.0"),
            },
            None,
        ),
        (
            "duplicate story code",
            {"docs/roadmap.md": ROADMAP_HEAD + story("C.0", "Draft") + story("C.0", "Draft")},
            "duplicate",
        ),
        (
            "planning doc without a Story line",
            {"docs/planning/C0.md": "# C.0 — Title\n\nNo story here.\n"},
            "Story:",
        ),
        (
            "planning doc citing an unknown story",
            {"docs/planning/C9.md": plan("C.9")},
            "unknown story C.9",
        ),
        (
            "adr without a status",
            {"docs/adr/0001-title.md": "# ADR-0001: Title\n\n## Context\n"},
            "Status",
        ),
        (
            "adr with an unknown status",
            {"docs/adr/0001-title.md": adr("Maybe"), "docs/adr/README.md": adr_index("Maybe")},
            "unknown ADR status",
        ),
        (
            "adr superseded by a missing adr",
            {
                "docs/adr/0001-title.md": adr("Superseded by ADR-0007"),
                "docs/adr/README.md": adr_index("Superseded by ADR-0007"),
            },
            "ADR-0007",
        ),
        (
            "adr index out of sync with the file",
            {"docs/adr/README.md": adr_index("Accepted")},
            "index",
        ),
    ]

    def test_cases(self):
        for name, override, want in self.CASES:
            with self.subTest(name), Repo(base_files(**override)) as root:
                errors = cm.check_repo(root)
                if want is None:
                    self.assertEqual(errors, [], name)
                else:
                    self.assertTrue(any(want in e for e in errors), f"{name}: {errors}")


class AdrImmutability(unittest.TestCase):
    CASES = [
        # (name, base content, head content, expected substring or None)
        ("proposed adr may change", adr("Proposed"), adr("Proposed", "## Context\n\nNew.\n"), None),
        ("proposed to accepted", adr("Proposed"), adr("Accepted"), None),
        (
            "accepted adr body edited",
            adr("Accepted"),
            adr("Accepted", "## Context\n\nRewritten.\n"),
            "immutable",
        ),
        ("accepted adr superseded", adr("Accepted"), adr("Superseded by ADR-0002"), None),
        (
            "accepted adr superseded and edited",
            adr("Accepted"),
            adr("Superseded by ADR-0002", "## Context\n\nRewritten.\n"),
            "immutable",
        ),
        ("accepted adr deleted", adr("Accepted"), None, "deleted"),
        ("accepted adr status reverted", adr("Accepted"), adr("Proposed"), "immutable"),
    ]

    def test_cases(self):
        for name, base, head, want in self.CASES:
            with self.subTest(name):
                errors = cm.check_adr_change("docs/adr/0001-title.md", base, head)
                if want is None:
                    self.assertEqual(errors, [], name)
                else:
                    self.assertTrue(any(want in e for e in errors), f"{name}: {errors}")


class AdrDiffInGit(unittest.TestCase):
    """check_adr_diff on a real repository: what git reports is the input."""

    def git(self, root, *args):
        subprocess.run(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", *args],
                       check=True, capture_output=True)

    def test_renamed_and_edited_accepted_adr_fails(self):
        with Repo({"docs/adr/0001-title.md": adr("Accepted")}) as root:
            self.git(root, "init", "-q", "-b", "main")
            self.git(root, "add", ".")
            self.git(root, "commit", "-qm", "base")
            self.git(root, "switch", "-q", "-c", "pr")
            self.git(root, "mv", "docs/adr/0001-title.md", "docs/adr/0001-new-title.md")
            with open(os.path.join(root, "docs/adr/0001-new-title.md"), "a", encoding="utf-8") as f:
                f.write("\nOne more line, which git still calls a rename.\n")
            self.git(root, "commit", "-qam", "rename and edit")
            errors = cm.check_adr_diff(root, "main")
            self.assertTrue(any("never deleted" in e for e in errors), errors)

    def test_new_adr_passes(self):
        with Repo({"docs/adr/0001-title.md": adr("Accepted")}) as root:
            self.git(root, "init", "-q", "-b", "main")
            self.git(root, "add", ".")
            self.git(root, "commit", "-qm", "base")
            self.git(root, "switch", "-q", "-c", "pr")
            with open(os.path.join(root, "docs/adr/0002-next.md"), "w", encoding="utf-8") as f:
                f.write(adr("Proposed"))
            self.git(root, "add", ".")
            self.git(root, "commit", "-qm", "new adr")
            self.assertEqual(cm.check_adr_diff(root, "main"), [])


class PrCitesStory(unittest.TestCase):
    CASES = [
        ("cites a known story", "Implements C.1.", None),
        ("cites C.0 in prose", "The first story to approve is **C.0**.", None),
        ("explicit no-story reason", "No story: repo housekeeping.", None),
        ("no-story without a reason", "No story:", "story"),
        ("cites nothing", "Fix typo.", "story"),
        ("cites an unknown story", "Implements C.42.", "story"),
    ]

    def test_cases(self):
        for name, body, want in self.CASES:
            with self.subTest(name):
                errors = cm.check_pr_body(body, {"C.0", "C.1"})
                if want is None:
                    self.assertEqual(errors, [], name)
                else:
                    self.assertTrue(any(want in e for e in errors), f"{name}: {errors}")


class RelativeLinks(unittest.TestCase):
    CASES = [
        ("link resolves", {"docs/a.md": "[b](b.md)\n", "docs/b.md": "# B\n"}, None),
        ("broken link", {"docs/a.md": "[b](missing.md)\n"}, "missing.md"),
        ("anchor is stripped", {"docs/a.md": "[b](b.md#x)\n", "docs/b.md": "# B\n"}, None),
        ("external links are skipped", {"docs/a.md": "[x](https://example.com)\n"}, None),
        ("pure anchors are skipped", {"docs/a.md": "[x](#top)\n"}, None),
        ("links in code fences are skipped", {"docs/a.md": "```\n[x](nope.md)\n```\n"}, None),
    ]

    def test_cases(self):
        for name, files, want in self.CASES:
            with self.subTest(name), Repo(files) as root:
                errors = cm.check_links(root)
                if want is None:
                    self.assertEqual(errors, [], name)
                else:
                    self.assertTrue(any(want in e for e in errors), f"{name}: {errors}")


if __name__ == "__main__":
    unittest.main()
