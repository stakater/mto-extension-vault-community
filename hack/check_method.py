#!/usr/bin/env python3
"""Mechanical checks for the method (docs/method.md, "Enforced by").

Deterministic, stdlib only. Each check returns a list of error strings; an
empty list means the rule holds.

    check_method.py repo [--root .]
    check_method.py links [--root .]
    check_method.py adr-diff --base <git ref> [--root .]
    check_method.py pr-body --body-file <file> [--root .]
"""

import argparse
import os
import re
import subprocess
import sys

STATUSES = {
    "Draft": "📝",
    "Approved": "👍",
    "In progress": "🔨",
    "Done": "✅",
}
NEEDS_DONE_LINE = {"Approved", "In progress", "Done"}
NEEDS_PLAN = {"In progress", "Done"}

STORY_RE = re.compile(r"^\*\*Story (?P<code>[A-Z]+\.\d+) — [^*]+\*\* (?P<marker>\S+) \*(?P<status>[^*]+)\*")
STORY_CODE_RE = re.compile(r"\b([A-Z]+\.\d+)\b")
PLAN_STORY_RE = re.compile(r"^Story: `docs/roadmap\.md` (?P<code>[A-Z]+\.\d+)\b", re.M)
ADR_STATUS_RE = re.compile(r"^- \*\*Status:\*\* (?P<status>.+?)\s*$", re.M)
ADR_STATUS_OK = re.compile(r"^(Proposed|Accepted|Rejected|Deprecated|Superseded by ADR-(?P<by>\d{4}))$")
ADR_INDEX_ROW = re.compile(r"^\| \[(?P<num>\d{4})\]\((?P<file>[^)]+)\) \|.*\| (?P<status>[^|]+?) \|\s*$", re.M)
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FROZEN = ("Accepted", "Superseded")

ROADMAP = "docs/roadmap.md"
ADR_DIR = "docs/adr"
PLAN_DIR = "docs/planning"


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def parse_stories(text):
    """Return [(code, marker, status, block)] in order. A block runs to the next story or heading."""
    stories, current = [], None
    for line in text.splitlines():
        m = STORY_RE.match(line)
        if m or line.startswith("#"):
            if current:
                stories.append(current)
            current = None
        if m:
            current = [m.group("code"), m.group("marker"), m.group("status").strip(), line + "\n"]
        elif current:
            current[3] += line + "\n"
    if current:
        stories.append(current)
    return [tuple(s) for s in stories]


def story_codes(root):
    return {s[0] for s in parse_stories(read(root, ROADMAP))}


def plan_docs(root):
    """Return {path relative to docs/: story code or None} for every planning doc except TEMPLATE.md."""
    out = {}
    d = os.path.join(root, PLAN_DIR)
    if not os.path.isdir(d):
        return out
    for name in sorted(os.listdir(d)):
        if not name.endswith(".md") or name == "TEMPLATE.md":
            continue
        m = PLAN_STORY_RE.search(read(root, os.path.join(PLAN_DIR, name)))
        out["planning/" + name] = m.group("code") if m else None
    return out


def check_roadmap(root, plans):
    errors, seen, in_progress = [], set(), []
    planned = {code: path for path, code in plans.items() if code}
    for code, marker, status, block in parse_stories(read(root, ROADMAP)):
        where = f"{ROADMAP}: story {code}"
        if code in seen:
            errors.append(f"{where}: duplicate story code")
        seen.add(code)
        if status not in STATUSES:
            errors.append(f"{where}: unknown status '{status}' (want one of {', '.join(STATUSES)})")
            continue
        if marker != STATUSES[status]:
            errors.append(f"{where}: marker {marker} does not match status {status} ({STATUSES[status]})")
        if status in NEEDS_DONE_LINE and not re.search(r"^Done:", block, re.M):
            errors.append(f"{where}: an {status} story needs a 'Done:' line")
        if status == "In progress":
            in_progress.append(code)
        if status in NEEDS_PLAN and code not in planned:
            errors.append(f"{where}: {status} but no planning doc in {PLAN_DIR}/ cites it (plan before code)")
        if status == "Done" and code in planned and planned[code] not in block:
            errors.append(f"{where}: Done stories must link its planning doc ({planned[code]})")
    if len(in_progress) > 1:
        errors.append(f"{ROADMAP}: {', '.join(in_progress)} are all In progress; one story at a time")
    return errors


def check_plans(plans, codes):
    errors = []
    for path, code in plans.items():
        if code is None:
            errors.append(f"docs/{path}: needs a 'Story: `docs/roadmap.md` <code>' line")
        elif code not in codes:
            errors.append(f"docs/{path}: cites unknown story {code}")
    return errors


def adr_files(root):
    d = os.path.join(root, ADR_DIR)
    if not os.path.isdir(d):
        return []
    return sorted(n for n in os.listdir(d) if re.match(r"^\d{4}-.+\.md$", n))


def adr_status(text):
    m = ADR_STATUS_RE.search(text)
    return m.group("status") if m else None


def check_adrs(root):
    errors, statuses = [], {}
    files = adr_files(root)
    numbers = {n[:4] for n in files}
    for name in files:
        rel = f"{ADR_DIR}/{name}"
        status = adr_status(read(root, rel))
        statuses[name] = status
        if status is None:
            errors.append(f"{rel}: missing '- **Status:** ...' line")
            continue
        m = ADR_STATUS_OK.match(status)
        if not m:
            errors.append(f"{rel}: unknown ADR status '{status}'")
        elif m.group("by") and m.group("by") not in numbers:
            errors.append(f"{rel}: superseded by ADR-{m.group('by')}, which does not exist")
    index = os.path.join(root, ADR_DIR, "README.md")
    if os.path.exists(index):
        for row in ADR_INDEX_ROW.finditer(read(root, f"{ADR_DIR}/README.md")):
            name, want = row.group("file"), statuses.get(row.group("file"))
            if want is not None and row.group("status").strip() != want:
                errors.append(
                    f"{ADR_DIR}/README.md: index says {row.group('num')} is '{row.group('status').strip()}', file says '{want}'"
                )
    return errors


def check_repo(root):
    plans = plan_docs(root)
    return check_roadmap(root, plans) + check_plans(plans, story_codes(root)) + check_adrs(root)


def without_status(text):
    return ADR_STATUS_RE.sub("", text)


def check_adr_change(path, base, head):
    """An Accepted (or Superseded) ADR is immutable: only Accepted -> Superseded by ADR-NNNN may change."""
    base_status = adr_status(base or "")
    if base is None or not base_status or not base_status.startswith(FROZEN):
        return []
    if head is None:
        return [f"{path}: {base_status} ADRs are never deleted; supersede instead"]
    head_status = adr_status(head) or ""
    errors = []
    if head_status != base_status and not (base_status == "Accepted" and head_status.startswith("Superseded by ADR-")):
        errors.append(f"{path}: {base_status} ADRs are immutable; status may only move to 'Superseded by ADR-NNNN'")
    if without_status(head) != without_status(base):
        errors.append(f"{path}: {base_status} ADRs are immutable; write a new ADR that supersedes it")
    return errors


def git_show(root, ref, rel):
    r = subprocess.run(["git", "-C", root, "show", f"{ref}:{rel}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def check_adr_diff(root, base):
    r = subprocess.run(
        ["git", "-C", root, "diff", "--name-only", f"{base}...HEAD", "--", ADR_DIR],
        capture_output=True, text=True, check=True,
    )
    errors = []
    for rel in r.stdout.split():
        if re.match(rf"^{ADR_DIR}/\d{{4}}-.+\.md$", rel):
            head_path = os.path.join(root, rel)
            head = read(root, rel) if os.path.exists(head_path) else None
            errors += check_adr_change(rel, git_show(root, base, rel), head)
    return errors


def story_sort_key(code):
    prefix, num = code.split(".")
    return prefix, int(num)


def check_pr_body(body, codes):
    m = re.search(r"^No story: *(\S.*)?$", body, re.M)
    if m:
        return [] if m.group(1) else ["PR body: 'No story:' needs a reason"]
    if any(c in codes for c in STORY_CODE_RE.findall(body)):
        return []
    return [f"PR body: cite the story it serves (one of {', '.join(sorted(codes, key=story_sort_key))}) or write 'No story: <reason>'"]


def check_links(root):
    errors = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for name in filenames:
            if not name.endswith(".md"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            in_fence = False
            with open(path, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    if line.lstrip().startswith("```"):
                        in_fence = not in_fence
                        continue
                    if in_fence:
                        continue
                    for target in LINK_RE.findall(re.sub(r"`[^`]*`", "", line)):
                        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                            continue
                        target = target.split("#", 1)[0]
                        if not os.path.exists(os.path.normpath(os.path.join(dirpath, target))):
                            errors.append(f"{rel}:{n}: broken link {target}")
    return errors


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("check", choices=["repo", "links", "adr-diff", "pr-body"])
    p.add_argument("--root", default=".")
    p.add_argument("--base", help="git ref to diff ADRs against (adr-diff)")
    p.add_argument("--body-file", help="file holding the PR body (pr-body)")
    a = p.parse_args(argv)
    if a.check == "repo":
        errors = check_repo(a.root)
    elif a.check == "links":
        errors = check_links(a.root)
    elif a.check == "adr-diff":
        if not a.base:
            p.error("adr-diff needs --base")
        errors = check_adr_diff(a.root, a.base)
    else:
        if not a.body_file:
            p.error("pr-body needs --body-file")
        with open(a.body_file, encoding="utf-8") as f:
            errors = check_pr_body(f.read(), story_codes(a.root))
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else e, file=sys.stderr)
    print(f"{a.check}: {'ok' if not errors else f'{len(errors)} problem(s)'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
