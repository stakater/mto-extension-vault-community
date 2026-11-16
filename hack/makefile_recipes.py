#!/usr/bin/env python3
"""Recipe lines continued with a backslash inside single quotes (DX.4).

GNU make 4 (CI's Linux runner) keeps a backslash-newline in a recipe and
passes it to the shell, which keeps it inside single quotes: the program in
the quotes gets a `\\` and a newline. macOS make 3.81 removes the pair, so the
same recipe works on a Mac. lab-dex's jq program broke CI's lab that way.
Split such a program out of the Makefile (hack/lab/dex-config.jq), or keep it
on one line.

Usage: hack/makefile_recipes.py [Makefile] — prints each line, exits 1.
"""

import sys


def quoted_continuations(text):
    """Line numbers of recipe lines that end in a backslash with a single
    quote open. A recipe line starts with a tab; a recipe comment (`#` or
    `@#`) is skipped; the quote state carries across continued lines."""
    found, quote = [], None
    for n, line in enumerate(text.splitlines(), 1):
        if not line.startswith("\t"):
            quote = None
            continue
        body = line[1:]
        if quote is None and body.lstrip().lstrip("@-+").lstrip().startswith("#"):
            continue
        i = 0
        while i < len(body):
            c = body[i]
            if quote is None:
                if c == "\\":
                    i += 2
                    continue
                if c in "'\"":
                    quote = c
            elif quote == '"':
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    quote = None
            elif c == "'":
                quote = None
            i += 1
        continued = body.endswith("\\")
        if continued and quote == "'":
            found.append(n)
        if not continued:
            quote = None
    return found


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "Makefile"
    with open(path, encoding="utf-8") as f:
        found = quoted_continuations(f.read())
    for n in found:
        print(f"{path}:{n}: a recipe line continued inside single quotes: GNU make keeps the backslash-newline")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
