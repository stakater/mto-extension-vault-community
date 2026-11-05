"""Tests for hack/mutation_tests.py's own rules (C.20): a kill is evidence
only through the mutation's own case, and a mutation applies to one match."""

import os
import shutil
import tempfile
import unittest

import mutation_tests as mt


def render(detail=None, count=1, old="guard"):
    return mt.m("x", "render", "f.tpl", old, "", "ssogroups", count=count, detail=detail)


class KillRulesTest(unittest.TestCase):
    def test_a_case_refused_by_another_guard_is_no_kill(self):
        line = "FAIL  ssogroups —  [bootstrap role-fallback failed elsewhere: Error: has no roleCaps entry]"
        why = mt.weak(render(), line)
        self.assertIsNotNone(why)
        self.assertIn("failed elsewhere", why)

    def test_a_template_crash_is_no_kill(self):
        line = ('FAIL  scopebranches —  [kv-parts failed: Error: template: x.yaml:1:28: executing "x.yaml" '
                "at <include>: error calling include: index out of range: 5]")
        self.assertIsNotNone(mt.weak(render(), line))

    def test_the_mutations_own_case_is_a_kill(self):
        line = "FAIL  ssogroups —  [bootstrap one-group rendered, want 'x'] [bootstrap y failed elsewhere: z]"
        self.assertIsNone(mt.weak(render(detail="[bootstrap one-group rendered"), line))

    def test_a_detail_not_in_the_line_is_no_kill(self):
        line = "FAIL  ssogroups —  [bootstrap one-group failed elsewhere: can give two tenants the same group]"
        self.assertIsNotNone(mt.weak(render(detail="[bootstrap one-group rendered"), line))

    def test_a_clean_line_is_a_kill(self):
        self.assertIsNone(mt.weak(render(), "FAIL  ssogroups —  [bootstrap fallback-allow rendered, want 'deny']"))


class MatchRulesTest(unittest.TestCase):
    def test_count_one_with_two_matches_fails(self):
        why = mt.matches(render(), "guard\nguard\n")
        self.assertIsNotNone(why)
        self.assertIn("2 matches", why)

    def test_count_all_with_two_matches_applies(self):
        self.assertIsNone(mt.matches(render(count="all"), "guard\nguard\n"))

    def test_no_match_fails(self):
        why = mt.matches(render(), "other\n")
        self.assertIsNotNone(why)
        self.assertIn("no match", why)

    def test_an_ambiguous_mutation_is_not_applied(self):
        repo = tempfile.mkdtemp()
        try:
            with open(os.path.join(repo, "f.tpl"), "w", encoding="utf-8") as fh:
                fh.write("guard\nguard\n")
            verdict, detail = mt.try_mutation(render(), repo, dict(os.environ))
            self.assertEqual(verdict, "NOT-APPLIED", detail)
            with open(os.path.join(repo, "f.tpl"), encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "guard\nguard\n")
        finally:
            shutil.rmtree(repo)


if __name__ == "__main__":
    unittest.main()
