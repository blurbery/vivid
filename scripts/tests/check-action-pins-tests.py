#!/usr/bin/env python3
"""Exercise scripts/ci/check-action-pins.py on the forms a workflow can use.

Needs Ruby, which the checker uses to parse YAML.
"""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("check_action_pins", root / "scripts/ci/check-action-pins.py")
check_action_pins = module_from_spec(spec)
spec.loader.exec_module(check_action_pins)

SHA = "11d5960a326750d5838078e36cf38b85af677262"


def workflow(steps="", job=""):
    """A workflow with one job, the given extra job keys and steps."""
    return f"name: Test\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n{job}    steps:\n{steps}"


def problems(text):
    return [message for _, message in check_action_pins.problems_in(text)]


class PinTests(unittest.TestCase):
    def test_pinned_actions_pass(self):
        steps = (f"      - uses: actions/checkout@{SHA} # v4\n"
                 f"      - uses: 'actions/checkout@{SHA}' # v4\n"
                 f"      - {{ name: x, uses: actions/checkout@{SHA} }} # v4\n"
                 "      - uses: ./local-action\n"
                 "      - uses: docker://alpine:3\n")
        self.assertEqual(problems(workflow(steps)), [])
        reusable = f"name: Test\non: push\njobs:\n  call:\n    uses: owner/repo/.github/workflows/x.yml@{SHA} # v1\n"
        self.assertEqual(problems(reusable), [])

    def test_tags_and_branches_fail(self):
        steps = ("      - uses: actions/checkout@v4\n"
                 "      - uses: \"actions/setup-node@v4\"\n"
                 "      - { uses: actions/cache@v4 }\n"
                 "      - { name: x, uses: actions/cache@v5 }\n")
        self.assertEqual(len(problems(workflow(steps))), 4)
        reusable = "name: Test\non: push\njobs:\n  call:\n    uses: owner/repo/.github/workflows/x.yml@v1\n"
        self.assertEqual(len(problems(reusable)), 1)

    def test_yaml_forms_are_read_as_github_reads_them(self):
        cases = {
            "explicit key": "      - ? uses\n        : actions/checkout@v4\n",
            "block scalar": "      - uses: >-\n          actions/checkout@v4\n",
            "value on the next line": "      - uses:\n          actions/checkout@v4\n",
            "quote after a dash in a plain value": "      - { name: a-'x, uses: owner/repo@v4 }\n",
            "apostrophe in a plain value": "      - { name: it's an action, uses: owner/repo@v4 }\n",
            "after a block scalar": "      - if: |\n          cond\n        uses: actions/checkout@v4\n",
        }
        for name, steps in cases.items():
            with self.subTest(name):
                found = problems(workflow(steps))
                self.assertEqual(len(found), 1, found)
                self.assertIn("not pinned", found[0])

    def test_text_that_is_not_a_step_key_is_ignored(self):
        steps = (f"      - {{ name: \"a, uses: b@v1\", uses: actions/checkout@{SHA} }} # v4\n"
                 "      - name: script\n"
                 "        run: |\n"
                 "          uses: fake@v1\n"
                 f"      - uses: actions/github-script@{SHA} # v7\n"
                 "        with:\n"
                 "          uses: an-input@v1\n")
        self.assertEqual(problems(workflow(steps)), [])

    def test_version_comment_is_required(self):
        found = problems(workflow(f"      - uses: actions/checkout@{SHA}\n"))
        self.assertEqual(len(found), 1)
        self.assertIn("version comment", found[0])

    def test_problems_land_on_their_own_lines(self):
        steps = ("      # actions/checkout@v4 is named here first\n"
                 "      - uses: actions/checkout@v4\n"
                 "      - run: echo\n"
                 "      - uses: actions/checkout@v4\n")
        text = workflow(steps)
        lines = text.splitlines()
        reported = [number for number, _ in check_action_pins.problems_in(text)]
        self.assertEqual([lines[number - 1].strip() for number in reported],
                         ["- uses: actions/checkout@v4", "- uses: actions/checkout@v4"])
        self.assertEqual(len(set(reported)), 2)

    def test_other_mentions_of_a_pin_need_no_comment(self):
        steps = (f"      # Pinned to actions/checkout@{SHA} below.\n"
                 f"      - uses: actions/checkout@{SHA} # v4\n"
                 f"      - run: echo actions/checkout@{SHA}\n")
        self.assertEqual(problems(workflow(steps)), [])

    def test_invalid_yaml_is_reported(self):
        found = problems("jobs: [unclosed\n")
        self.assertEqual(len(found), 1)
        self.assertIn("couldn't be read as YAML", found[0])

    def test_repository_workflows_pass(self):
        for path in sorted((root / ".github/workflows").glob("*.y*ml")):
            with self.subTest(workflow=path.name):
                self.assertEqual(problems(path.read_text()), [])


if __name__ == "__main__":
    unittest.main()
