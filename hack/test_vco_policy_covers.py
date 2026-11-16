"""Tests for hack/vco_policy_covers.py (C.23): the check that VCO's policy
covers every Vault path VCO writes for the charts' render."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vco_policy_covers as vpc  # noqa: E402

POLICY = '''
# a comment with path "sys/auth/+/x" { capabilities = ["update"] }
path "sys/auth/+/kubernetes/workloads" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
  allowed_parameters = {
    "type" = ["kubernetes"]
    "*"    = []
  }
}
path "sys/auth/+/kubernetes/workloads/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/policy/kv.*" {
  capabilities = ["create", "read", "update", "delete"]
}
'''


def mount(path="team-a/kubernetes", name="workloads"):
    return {"kind": "AuthEngineMount", "metadata": {"name": "team-a-kubernetes"}, "spec": {"path": path, "name": name}}


def policy(name, spec_name=None):
    spec = {"policy": "x"}
    if spec_name:
        spec["name"] = spec_name
    return {"kind": "Policy", "metadata": {"name": name}, "spec": spec}


class GlobTest(unittest.TestCase):
    def test_plus_matches_one_segment(self):
        g = vpc.glob_re("sys/auth/+/kubernetes/workloads")
        self.assertTrue(g.match("sys/auth/team-a/kubernetes/workloads"))
        self.assertFalse(g.match("sys/auth/a/b/kubernetes/workloads"))
        self.assertFalse(g.match("sys/auth/team-a/kubernetes/workloads/x"))

    def test_star_is_a_prefix(self):
        g = vpc.glob_re("sys/policy/kv.*")
        self.assertTrue(g.match("sys/policy/kv.team-a.ns.web"))
        self.assertFalse(g.match("sys/policy/share.team-a.ns.web.out.team-b"))


class CheckTest(unittest.TestCase):
    def check(self, crs, text=POLICY, replace=()):
        return vpc.check(crs, [("p.hcl", text)], replace)

    def test_covered_mount_passes(self):
        self.assertEqual(self.check([mount()]), [])

    def test_a_comment_is_no_stanza(self):
        self.assertEqual(len(vpc.stanzas(POLICY)), 3)

    def test_uncovered_path_fails(self):
        f = self.check([mount("team-a/k8s", "apps")])
        self.assertTrue(f and "sys/auth/team-a/k8s/apps" in f[0] and "no stanza" in f[0], f)

    def test_two_stanzas_fail(self):
        f = self.check([mount()], POLICY + 'path "sys/auth/+/+/workloads" {\n  capabilities = ["update"]\n}\n')
        self.assertTrue(any("2 stanzas" in x for x in f), f)

    def test_read_only_is_no_write(self):
        f = self.check([policy("kv.team-a.ns.web")], 'path "sys/policy/kv.*" {\n  capabilities = ["read", "list"]\n}\n')
        self.assertTrue(f and "no write" in f[0], f)

    def test_unknown_kind_fails(self):
        f = self.check([{"kind": "AppRoleAuthEngineRole", "metadata": {"name": "x"}, "spec": {"path": "team-a/approle"}}])
        self.assertTrue(f and "AppRoleAuthEngineRole" in f[0], f)

    def test_replace_applies_before_the_match(self):
        self.assertEqual(self.check([mount("team-a/k8s", "apps")], replace=[("kubernetes/workloads", "k8s/apps")]), [])

    def test_policy_name_from_spec(self):
        self.assertEqual(vpc.vault_paths(policy("kv.a.b.c", spec_name="kv.x.y.z")), ["sys/policy/kv.x.y.z"])
        self.assertEqual(vpc.vault_paths(policy("kv.a.b.c")), ["sys/policy/kv.a.b.c"])

    def test_each_kind_maps_to_its_paths(self):
        cases = [
            ({"kind": "SecretEngineMount", "spec": {"path": "team-a", "name": "kv"}},
             ["sys/mounts/team-a/kv", "sys/mounts/team-a/kv/tune"]),
            ({"kind": "KubernetesAuthEngineConfig", "spec": {"path": "team-a/kubernetes", "name": "workloads"}},
             ["auth/team-a/kubernetes/workloads/config"]),
            ({"kind": "KubernetesAuthEngineRole", "spec": {"path": "team-a/kubernetes/workloads", "name": "kv.team-a.ns.web"}},
             ["auth/team-a/kubernetes/workloads/role/kv.team-a.ns.web"]),
            ({"kind": "JWTOIDCAuthEngineConfig", "spec": {"path": "team-a/oidc/sso"}},
             ["auth/team-a/oidc/sso/config"]),
            ({"kind": "JWTOIDCAuthEngineRole", "spec": {"path": "team-a/oidc/sso", "name": "sso.team-a.editor"}},
             ["auth/team-a/oidc/sso/role/sso.team-a.editor"]),
        ]
        for cr, want in cases:
            cr.setdefault("metadata", {"name": "x"})
            self.assertEqual(vpc.vault_paths(cr), want, cr["kind"])


if __name__ == "__main__":
    unittest.main()
