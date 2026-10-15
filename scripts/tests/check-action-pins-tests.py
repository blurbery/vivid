#!/usr/bin/env python3
"""Exercise scripts/ci/check-action-pins.py on the forms a workflow can use."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("check_action_pins", root / "scripts/ci/check-action-pins.py")
check_action_pins = module_from_spec(spec)
spec.loader.exec_module(check_action_pins)

SHA = "11d5960a326750d5838078e36cf38b85af677262"


def lines(text):
    return [number for number, _ in check_action_pins.problems_in(text)]


class PinTests(unittest.TestCase):
    def test_pinned_actions_pass(self):
        text = (f"    uses: owner/repo/.github/workflows/x.yml@{SHA} # v1\n"
                f"      - uses: actions/checkout@{SHA} # v4\n"
                f"      - uses: 'actions/checkout@{SHA}' # v4\n"
                f"      - {{ name: x, uses: actions/checkout@{SHA} }} # v4\n"
                "      - uses: ./local-action\n"
                "      - uses: docker://alpine:3\n"
                f"      - uses: actions/checkout@{SHA} # v4 @{SHA}\n")
        self.assertEqual(lines(text), [])

    def test_tags_and_branches_fail(self):
        text = ("    uses: owner/repo/.github/workflows/x.yml@v1\n"
                "      - uses: actions/checkout@v4\n"
                "      - uses: \"actions/setup-node@v4\"\n"
                "      - { uses: actions/cache@v4 }\n"
                "      - { name: x, uses: actions/cache@v5 }\n"
                "      steps: [{ uses: actions/cache@v4 }]\n")
        self.assertEqual(lines(text), [1, 2, 3, 4, 5, 6])

    def test_version_comment_is_required(self):
        problems = check_action_pins.problems_in(f"      - uses: actions/checkout@{SHA}\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("version comment", problems[0][1])

    def test_action_on_a_later_line_fails(self):
        text = ("      - uses: >-\n          actions/checkout@v4\n"
                "      - uses:\n          actions/checkout@v4\n")
        self.assertEqual(lines(text), [1, 3])

    def test_explicit_keys(self):
        self.assertEqual(lines("      - ? uses\n        : actions/checkout@v4\n"), [2])
        self.assertEqual(lines(f"      - ? uses\n        : actions/checkout@{SHA} # v4\n"), [])

    def test_quoted_text_is_not_a_key(self):
        text = (f"      - {{ name: \"a, uses: b@v1\", uses: actions/checkout@{SHA} }} # v4\n"
                "      - { name: 'x, uses: y@v1', run: echo }\n")
        self.assertEqual(lines(text), [])

    def test_apostrophes_in_plain_values_are_text(self):
        self.assertEqual(lines("      - { name: it's an action, uses: owner/repo@v4 }\n"), [1])
        self.assertEqual(lines("      - { name: 'it''s, uses: x@v1', uses: owner/repo@v4 }\n"), [1])
        self.assertEqual(lines("      - { name: the 'x, uses: owner/repo@v4 }\n"), [1])
        self.assertEqual(lines("      - { name: \"a\", uses: owner/repo@v4 }\n"), [1])
        self.assertEqual(lines("      - 'uses': owner/repo@v4\n"), [1])

    def test_block_scalars_are_skipped(self):
        text = ("      - name: script\n"
                "        run: |2+\n"
                "          uses: fake@v1\n"
                f"      - uses: actions/github-script@{SHA} # v7\n"
                "        with:\n"
                "          script: |\n"
                "            uses: fake@v1\n")
        self.assertEqual(lines(text), [])

    def test_steps_opening_with_a_block_scalar_are_still_checked(self):
        text = ("      - if: |\n          cond\n        uses: actions/checkout@v4\n"
                "      - name: >-\n          Long name\n        uses: actions/checkout@v4\n")
        self.assertEqual(lines(text), [3, 6])

    def test_repository_workflows_pass(self):
        for workflow in sorted((root / ".github/workflows").glob("*.y*ml")):
            with self.subTest(workflow=workflow.name):
                self.assertEqual(check_action_pins.problems_in(workflow.read_text()), [])


if __name__ == "__main__":
    unittest.main()
