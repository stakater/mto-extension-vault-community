"""Tests for hack/makefile_recipes.py (DX.4): a recipe line continued with a
backslash inside single quotes works with macOS make 3.81, which removes the
backslash-newline, and breaks with GNU make 4, which keeps it."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import makefile_recipes as mr  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class QuotedContinuationTest(unittest.TestCase):
    def test_the_makefile_has_none(self):
        with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as f:
            found = mr.quoted_continuations(f.read())
        self.assertEqual(found, [], "recipe lines continued inside single quotes (line numbers): "
                         "GNU make passes the backslash and newline to the program")

    def test_a_continuation_inside_single_quotes_is_found(self):
        text = "t:\n\tjq -n '{a: 1, \\\n\t  b: 2}'\n"
        self.assertEqual(mr.quoted_continuations(text), [2])

    def test_a_continuation_outside_quotes_is_fine(self):
        text = "t:\n\tjq -n --arg a 'x' \\\n\t  '{a: $$a}'\n"
        self.assertEqual(mr.quoted_continuations(text), [])

    def test_a_quote_inside_double_quotes_opens_nothing(self):
        text = "t:\n\techo \"it's\" \\\n\t  done\n"
        self.assertEqual(mr.quoted_continuations(text), [])

    def test_a_recipe_comment_is_skipped(self):
        text = "t:\n\t@# the issuer's document \\\n\techo ok\n"
        self.assertEqual(mr.quoted_continuations(text), [])

    def test_a_quote_open_over_two_continued_lines_is_found_on_each(self):
        text = "t:\n\tprintf '%s' 'a \\\n\t  b \\\n\t  c'\n"
        self.assertEqual(mr.quoted_continuations(text), [2, 3])


if __name__ == "__main__":
    unittest.main()
