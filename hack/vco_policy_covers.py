#!/usr/bin/env python3
"""Does VCO's policy cover every Vault path VCO writes for the charts' render?
(C.23)

Reads the rendered VCO CRs as JSON, one per line, on stdin. Maps each CR to the
Vault paths VCO writes for it, and checks each path against every policy file:
exactly one `path` stanza must match (Vault picks one by priority, so two that
match hide which one applies), and that stanza must allow a write (`create`
or `update`). `--replace old=new` applies to the policy text first: it is the
rule `charts/README.md` gives for mounts that are not the defaults.

Vault's globs: `+` is one path segment, a final `*` a prefix.

Prints one `FAIL  policypaths <label>: …` line per path a policy misses, and
exits 1 when there is one.
"""

import argparse
import json
import re
import sys

WRITE = {"create", "update"}
STANZA = re.compile(r'^path\s+"([^"]+)"\s*\{(.*?)^\}', re.M | re.S)
CAPS = re.compile(r'capabilities\s*=\s*\[([^\]]*)\]')


def stanzas(text):
    """[(pattern, {capabilities})] of a policy, comments left out."""
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    out = []
    for pattern, inner in STANZA.findall(body):
        m = CAPS.search(inner)
        out.append((pattern, set(re.findall(r'"([a-z]+)"', m.group(1))) if m else set()))
    return out


def glob_re(pattern):
    prefix = pattern.endswith("*")
    if prefix:
        pattern = pattern[:-1]
    parts = ["[^/]+" if s == "+" else re.escape(s) for s in pattern.split("/")]
    return re.compile("/".join(parts) + (".*" if prefix else "") + r"\Z")


def vault_paths(cr):
    """The Vault paths VCO writes for one CR."""
    kind, spec = cr["kind"], cr.get("spec") or {}
    path, name = str(spec.get("path", "")).strip("/"), spec.get("name")
    if kind == "SecretEngineMount":
        return [f"sys/mounts/{path}/{name}", f"sys/mounts/{path}/{name}/tune"]
    if kind == "AuthEngineMount":
        return [f"sys/auth/{path}/{name}", f"sys/auth/{path}/{name}/tune"]
    if kind == "KubernetesAuthEngineConfig":
        return [f"auth/{path}/{name}/config"]
    if kind == "JWTOIDCAuthEngineConfig":
        return [f"auth/{path}/config"]
    if kind in ("KubernetesAuthEngineRole", "JWTOIDCAuthEngineRole"):
        return [f"auth/{path}/role/{name}"]
    if kind == "Policy":
        return [f"sys/policy/{spec.get('name') or cr['metadata']['name']}"]
    raise ValueError(f"{kind}: no Vault path is mapped for this kind (hack/vco_policy_covers.py)")


def check(crs, policies, replace=()):
    """Failures, as text, for [cr] against [(file, policy text)]."""
    rules = []
    for f, text in policies:
        for old, new in replace:
            text = text.replace(old, new)
        rules.append((f, [(p, caps, glob_re(p)) for p, caps in stanzas(text)]))
    failures = []
    for cr in crs:
        what = f"{cr['kind']}/{(cr.get('metadata') or {}).get('name', '?')}"
        try:
            paths = vault_paths(cr)
        except ValueError as e:
            failures.append(f"{what}: {e}")
            continue
        for p in paths:
            for f, st in rules:
                hits = [(pat, caps) for pat, caps, g in st if g.match(p)]
                if not hits:
                    failures.append(f"{what} writes {p}: no stanza of {f} matches it")
                elif len(hits) > 1:
                    failures.append(f"{what} writes {p}: {len(hits)} stanzas of {f} match it ({', '.join(h[0] for h in hits)})")
                elif not (hits[0][1] & WRITE):
                    failures.append(f"{what} writes {p}: {f} matches it with {hits[0][0]!r}, which has no write (create or update)")
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--policy", action="append", required=True)
    ap.add_argument("--replace", action="append", default=[], help="old=new, applied to the policy text first")
    a = ap.parse_args()
    replace = [tuple(r.split("=", 1)) for r in a.replace]
    crs = [json.loads(l) for l in sys.stdin if l.strip()]
    if not crs:
        print(f"FAIL  policypaths {a.label}: no VCO CRs on stdin")
        return 1
    policies = [(f, open(f, encoding="utf-8").read()) for f in a.policy]
    failures = check(crs, policies, replace)
    for f in failures:
        print(f"FAIL  policypaths {a.label}: {f}")
    if failures:
        return 1
    n = sum(len(vault_paths(cr)) for cr in crs)
    print(f"== policypaths {a.label}: {len(crs)} VCO CRs, {n} Vault paths, each in one stanza that writes, of {' and '.join(a.policy)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
