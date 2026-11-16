"""Tests for hack/lab/dex-reachable.sh, make lab-dex's check that the Vault pod
reaches Dex (DX.3). A fake kubectl fails a set number of tries, then prints
Dex's discovery document, and records the arguments of every try."""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "hack", "lab", "dex-reachable.sh")
ISSUER = "http://dex.dex.svc.cluster.local:5556"

FAKE_KUBECTL = """#!/bin/sh
n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_DIR/count"
echo "$*" >> "$FAKE_DIR/args"
fails=$(cat "$FAKE_DIR/fails")
if [ "$fails" = all ] || [ "$n" -le "$fails" ]; then
  echo "wget: can't connect to remote host (10.96.18.242): Operation timed out" >&2
  exit 1
fi
cat "$FAKE_DIR/doc"
"""


class DexReachableTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.kubectl = os.path.join(self.dir, "kubectl")
        with open(self.kubectl, "w", encoding="utf-8") as f:
            f.write(FAKE_KUBECTL)
        os.chmod(self.kubectl, 0o755)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def run_check(self, fails, issuer=ISSUER, wait="20"):
        with open(os.path.join(self.dir, "fails"), "w", encoding="utf-8") as f:
            f.write(str(fails))
        with open(os.path.join(self.dir, "doc"), "w", encoding="utf-8") as f:
            json.dump({"issuer": issuer, "authorization_endpoint": issuer + "/auth"}, f)
        env = dict(os.environ, FAKE_DIR=self.dir, KUBECTL=self.kubectl, CONTEXT="kind-test",
                   VAULT_NS="vault", DEX_ISSUER=ISSUER, DEX_WAIT=wait, DEX_RETRY_SLEEP="0.1")
        start = time.monotonic()
        r = subprocess.run([SCRIPT], capture_output=True, text=True, env=env, timeout=60)
        return r, time.monotonic() - start

    def tries(self):
        with open(os.path.join(self.dir, "args"), encoding="utf-8") as f:
            return f.read().splitlines()

    def test_retries_until_dex_answers(self):
        r, _ = self.run_check(fails=2)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"Dex answers as {ISSUER} inside the Vault pod", r.stdout)
        self.assertEqual(len(self.tries()), 3)

    def test_gives_up_when_dex_never_answers(self):
        r, took = self.run_check(fails="all", wait="2")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"error: the Vault pod cannot reach Dex at {ISSUER}", r.stderr)
        self.assertIn("Operation timed out", r.stderr)
        self.assertGreater(len(self.tries()), 1, "it never tried again")
        self.assertLess(took, 10, "it did not stop at DEX_WAIT")

    def test_wrong_issuer_fails_at_once(self):
        r, _ = self.run_check(fails=0, issuer="http://other.example.com:5556")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"error: Dex's issuer is not {ISSUER}", r.stderr)
        self.assertEqual(len(self.tries()), 1, "a wrong issuer is a config error: no retry")

    def test_each_try_has_a_timeout(self):
        r, _ = self.run_check(fails=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        for t in self.tries():
            self.assertIn("exec vault-0 -- wget -T ", t)
            self.assertIn(f"{ISSUER}/.well-known/openid-configuration", t)


if __name__ == "__main__":
    unittest.main()
