"""Tests for hack/mutation_tests.py's own rules (C.20, C.21): a kill is
evidence only through the mutation's own case and never a crash, and a
mutation applies to one match."""

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


    def test_a_crash_on_the_own_case_is_no_kill(self):
        line = ('FAIL  ssogroups —  [bootstrap roles-string failed elsewhere: Error: template: x.yaml:1:2: '
                "executing \"x\" at <$roles>: range can't iterate over admin]")
        self.assertIsNotNone(mt.weak(render(detail="[bootstrap roles-string"), line))

    def test_each_crash_word_is_no_kill(self):
        # The words listed here, not mt.CRASH: a word dropped from the list
        # fails this test.
        for w in ('executing "', "parse error", "syntax error", "nil pointer", "can't evaluate field",
                  "wrong type for value", "index out of range", "command not found", "can't iterate"):
            line = f"FAIL  ssogroups —  [bootstrap x failed: Error: {w}]"
            self.assertIsNotNone(mt.weak(render(detail="[bootstrap x failed"), line), w)
            self.assertIsNotNone(mt.weak(render(), line), w)

    def test_each_weak_word_without_detail_is_no_kill(self):
        for w in ("failed elsewhere", "execution error at", "was refused", "did not render"):
            self.assertIsNotNone(mt.weak(render(), f"FAIL  installvalues —  [x {w}: y]"), w)

    def test_each_admission_error_word_is_no_kill(self):
        mut = mt.m("x", "admission", "f.yaml", "guard", "", "a case")
        for w in ("on an evaluation error", "resulted in error", "failed to configure"):
            self.assertIsNotNone(mt.weak(mut, f"FAIL  admit: a case (001.yaml): refused by p: {w}"), w)

    def test_another_guards_message_on_the_own_case_is_a_kill(self):
        line = ("FAIL  ssogroups —  [bootstrap one-group failed elsewhere: Error: execution error at "
                "(b/templates/x.yaml:1:2): can give two tenants the same group]")
        self.assertIsNone(mt.weak(render(detail="[bootstrap one-group failed elsewhere"), line))

    def test_a_crash_in_another_case_leaves_the_own_case_a_kill(self):
        line = ("FAIL  ssogroups —  [bootstrap one-group rendered, want 'x'] "
                "[bootstrap y failed: Error: template: x.yaml:1:2: index out of range: 5]")
        self.assertIsNone(mt.weak(render(detail="[bootstrap one-group rendered"), line))

    def test_helm_fail_output_without_detail_is_no_kill(self):
        line = ("FAIL  installvalues —  [parent: {token: {ttl: 0}} was refused: Error: execution error at "
                "(b/templates/01-checks.yaml:3:4): has no roleCaps entry]")
        self.assertIsNotNone(mt.weak(render(), line))

    def test_an_admission_evaluation_error_is_no_kill(self):
        mut = mt.m("x", "admission", "f.yaml", "guard", "", "a VCO CR without a spec")
        line = ("FAIL  refuse: a VCO CR without a spec (025.yaml): refused by p on an evaluation error, "
                "not by a rule: expression 'x' resulted in error: no such key: spec")
        self.assertIsNotNone(mt.weak(mut, line))
        self.assertIsNone(mt.weak(mut, "FAIL  refuse: a VCO CR without a spec (025.yaml): admitted by p"))
        # An admit case, or another policy, failed by an evaluation error: a crash too.
        admit = ("FAIL  admit: a config (091.yaml): refused by p: ... denied request: expression 'x' "
                 "resulted in error: no such key")
        self.assertIsNotNone(mt.weak(mut, admit))
        self.assertIsNotNone(mt.weak(mut, "FAIL  refuse: x (001.yaml): also refused by q: failed to configure policy"))
        self.assertIsNone(mt.weak(mt.m("c", "admission", "f.yaml", "g", "", "compile"), "FAIL  compile: p: syntax error"))

    def test_a_method_error_is_no_kill(self):
        self.assertIsNone(mt.killed_by("method", "test_x", "ERROR: test_x (m.T.test_x)"))
        self.assertIsNotNone(mt.killed_by("method", "test_x", "FAIL: test_x (m.T.test_x)"))

    def test_a_go_panic_is_no_kill(self):
        mut = mt.m("x", "go", "hack/admission-eval/main.go", "guard", "", "TestX")
        out = "--- FAIL: TestX (0.00s)\npanic: runtime error [recovered]\n"
        line = mt.killed_by("go", "TestX", out)
        self.assertIsNotNone(line)
        self.assertIsNotNone(mt.weak(mut, line, out))
        self.assertIsNone(mt.weak(mut, line, "--- FAIL: TestX (0.00s)\n"))

    def test_a_mutation_of_the_evaluator_runs_its_own_build(self):
        env = {"ADMISSION_EVAL": "/tmp/prebuilt", "HELM": "helm"}
        own = mt.m("x", "admission", "hack/admission-eval/main.go", "guard", "", "a case")
        other = mt.m("y", "admission", mt.ADM, "guard", "", "a case")
        self.assertNotIn("ADMISSION_EVAL", mt.suite_env(own, env))
        self.assertEqual(mt.suite_env(other, env), env)


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
