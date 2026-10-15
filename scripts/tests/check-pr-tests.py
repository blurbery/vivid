#!/usr/bin/env python3
"""Exercise scripts/ci/check-pr.py against titles, branches and descriptions."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("check_pr", root / "scripts/ci/check-pr.py")
check_pr = module_from_spec(spec)
spec.loader.exec_module(check_pr)

APP = ["iosApp/iosApp/Views/HomeView.swift"]
DOCS = ["docs/README.md", "CONTRIBUTING.md"]

FILLED = """## Problem and reproduction

Focus jumped to the top row.

## Implementation and impact

Keeps the focus on the last row.

## Validation

CI.

## Performance

Not applicable.

## Testing status

- **Tested?** Yes
- **Environment:** Apple TV 4K simulator

## Design impact and approval

> [!IMPORTANT]
> Only blurbery can approve design changes. Obtain prior, explicit approval and reference it here. Unapproved design changes must not be merged.

- **Design impact:** No design changes.
- **Approval from blurbery:** Not applicable, no design changes.

## Documentation impact

- No documentation changes: focus behaviour is not described anywhere.
- [x] I checked the docs this change affects and updated them in this PR, or explained above why none needed changes.

## AI disclosure

I implemented these changes and used Claude Opus as a tool.
"""


class TitleTests(unittest.TestCase):
    def test_conventional_titles_pass(self):
        for title in ("fix: keep focus on the last row",
                      "feat(tv): open Search from the Siri button",
                      "refactor!: drop the old player bridge",
                      "docs: fix a link [skip release]"):
            with self.subTest(title=title):
                self.assertEqual(check_pr.check_title(title, APP), [])

    def test_other_titles_fail(self):
        for title in ("Fix focus", "Fix: keep focus", "fix:keep focus", "feature: add Search",
                      'Revert "fix: keep focus"', "fix : keep focus", "fix(): keep focus"):
            with self.subTest(title=title):
                self.assertEqual(len(check_pr.check_title(title, APP)), 1)

    def test_upper_case_type_gets_a_hint(self):
        self.assertIn("lower case", check_pr.check_title("Fix: keep focus", APP)[0])

    def test_housekeeping_needs_skip_release(self):
        for files in (DOCS, [".github/workflows/pr-checks.yml"], ["iosApp/Tests/HomeTests.swift"],
                      ["engine/pins.ini"], ["website/public/privacy.html"], []):
            with self.subTest(files=files):
                problems = check_pr.check_title("docs: fix a link", files)
                self.assertEqual(len(problems), 1)
                self.assertIn("[skip release]", problems[0])
                self.assertEqual(check_pr.check_title("docs: fix a link [Skip Release]", files), [])

    def test_app_changes_may_release_or_skip(self):
        files = DOCS + APP
        self.assertEqual(check_pr.check_title("fix: keep focus", files), [])
        self.assertEqual(check_pr.check_title("fix: keep focus [skip release]", files), [])

    def test_unknown_files_skip_the_release_rule(self):
        self.assertEqual(check_pr.check_title("docs: fix a link", None), [])

    def test_build_phase_scripts_ship(self):
        self.assertEqual(check_pr.check_title("fix: stamp the source commit", ["scripts/xcode/stamp-source-revision.sh"]), [])

    def test_revert_title_hint(self):
        problems = check_pr.check_title('Revert "fix: keep focus on the last row"', APP)
        self.assertEqual(len(problems), 1)
        self.assertIn("revert:", problems[0])


class BranchTests(unittest.TestCase):
    def test_typed_branches_pass(self):
        for branch in ("fix/row-focus", "feat/tv-siri-search", "experiment/lucid-engine-build",
                       "release/0.39", "ci/pr-checks", "docs/sync_final.features",
                       "revert-148-fix/trailer-alert"):
            with self.subTest(branch=branch):
                self.assertEqual(check_pr.check_branch(branch), [])

    def test_other_branches_fail(self):
        for branch in ("claude/competent-thompson-54984c", "batch/playback", "experiment-2.0",
                       "main", "fix/", "fix", "Fix/row-focus", "fix/-row"):
            with self.subTest(branch=branch):
                self.assertEqual(len(check_pr.check_branch(branch)), 1)


class DescriptionTests(unittest.TestCase):
    def test_filled_description_passes(self):
        self.assertEqual(check_pr.check_description(FILLED), [])

    def test_windows_line_endings_pass(self):
        self.assertEqual(check_pr.check_description(FILLED.replace("\n", "\r\n")), [])

    def test_untouched_template_fails_every_section(self):
        problems = check_pr.check_description(check_pr.TEMPLATE.read_text())
        self.assertEqual(len(problems), len(check_pr.SECTIONS))

    def test_empty_description_fails(self):
        self.assertEqual(len(check_pr.check_description("")), len(check_pr.SECTIONS))
        self.assertEqual(len(check_pr.check_description(None)), len(check_pr.SECTIONS))

    def test_missing_section(self):
        body = FILLED.replace("## Performance\n\nNot applicable.\n", "")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("## Performance", problems[0])

    def test_comment_only_section_is_empty(self):
        body = FILLED.replace("Not applicable.\n", "<!-- Say why benchmarks do not apply. -->\n")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn('"Performance" is empty', problems[0])

    def test_unticked_docs_box(self):
        body = FILLED.replace("- [x] I checked", "- [ ] I checked")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("tick", problems[0])

    def test_ticked_box_alone_is_not_enough(self):
        body = FILLED.replace("- No documentation changes: focus behaviour is not described anywhere.\n", "")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("list the docs", problems[0])

    def test_blank_design_field(self):
        body = FILLED.replace("- **Approval from blurbery:** Not applicable, no design changes.",
                              "- **Approval from blurbery:**")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("Approval from blurbery", problems[0])

    def test_missing_design_field(self):
        body = FILLED.replace("- **Approval from blurbery:** Not applicable, no design changes.\n", "")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("no **Approval from blurbery:** line", problems[0])

    def test_testing_status_as_one_sentence(self):
        body = FILLED.replace("- **Tested?** Yes\n- **Environment:** Apple TV 4K simulator\n",
                              "Not applicable, documentation-only change.\n")
        self.assertEqual(check_pr.check_description(body), [])
        partly = FILLED.replace("- **Tested?** Yes\n", "")
        problems = check_pr.check_description(partly)
        self.assertEqual(len(problems), 1)
        self.assertIn("no **Tested?** line", problems[0])

    def test_blank_tested_field(self):
        body = FILLED.replace("- **Tested?** Yes", "- **Tested?** <!-- Yes / No / Partly -->")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("Tested?", problems[0])

    def test_ai_disclosure_fields(self):
        fields = ("- **Tools / assistants used:** GitHub Copilot\n"
                  "- **Models used:** Label unavailable\n"
                  "- **What AI helped with:** Tests\n"
                  "- **My direction, review and validation:** I wrote and checked the fix.\n")
        body = FILLED.replace("I implemented these changes and used Claude Opus as a tool.\n", fields)
        self.assertEqual(check_pr.check_description(body), [])
        partly = body.replace("- **Models used:** Label unavailable", "- **Models used:**")
        problems = check_pr.check_description(partly)
        self.assertEqual(len(problems), 1)
        self.assertIn("Models used", problems[0])

    def test_blank_ai_disclosure(self):
        body = FILLED.replace("I implemented these changes and used Claude Opus as a tool.\n", "")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("AI disclosure", problems[0])

    def test_review_bot_block_does_not_fill_a_section(self):
        body = FILLED.replace("I implemented these changes and used Claude Opus as a tool.\n", "") + (
            "<!-- This is an auto-generated description by cubic. -->\n"
            '<a href="https://example.com">View guided diff</a>\n'
            "<!-- End of auto-generated description by cubic. -->\n")
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("AI disclosure", problems[0])

    def test_field_values_on_indented_lines(self):
        body = FILLED.replace("- **Design impact:** No design changes.",
                              "- **Design impact:**\n  - The Home row spacing, approved in #120.")
        self.assertEqual(check_pr.check_description(body), [])
        fields = ("- **Tools / assistants used:** GitHub Copilot\n"
                  "- **Models used:** Label unavailable\n"
                  "- **What AI helped with:**\n  - Code\n  - Tests\n"
                  "- **My direction, review and validation:** I wrote and checked the fix.\n")
        body = FILLED.replace("I implemented these changes and used Claude Opus as a tool.\n", fields)
        self.assertEqual(check_pr.check_description(body), [])

    def test_other_markdown_forms(self):
        body = (FILLED.replace("## Validation", "## **Validation** ✅")
                .replace("- [x] I checked", "+ [x] I checked")
                .replace("- **Approval from blurbery:** Not applicable", "- **Approval from blurbery**: Not applicable")
                .replace("## Performance", "  ## Performance"))
        self.assertEqual(check_pr.check_description(body), [])
        self.assertEqual(check_pr.check_description(FILLED.replace("- [x] I checked", "1. [x] I checked")), [])

    def test_headings_inside_code_fences(self):
        missing = FILLED.replace("## Performance\n\nNot applicable.\n", "")
        fenced = missing.replace("CI.\n", "CI.\n\n```text\n## Performance\nNot applicable.\n```\n")
        self.assertEqual(len(check_pr.check_description(fenced)), 1)
        comment = FILLED.replace("- No documentation changes", "```sh\n# regenerate\nxcodegen generate\n```\n- No documentation changes")
        self.assertEqual(check_pr.check_description(comment), [])

    def test_longer_fences_hold_shorter_ones(self):
        missing = FILLED.replace("## Performance\n\nNot applicable.\n", "")
        nested = missing.replace("CI.\n", "CI.\n\n````md\n```\n## Performance\nNot applicable.\n```\n````\n")
        problems = check_pr.check_description(nested)
        self.assertEqual(len(problems), 1)
        self.assertIn("## Performance", problems[0])

    def test_inline_code_at_line_start_is_not_a_fence(self):
        body = FILLED.replace("CI.\n", "```npm run test:release``` passes.\n")
        self.assertEqual(check_pr.check_description(body), [])

    def test_only_the_docs_box_counts(self):
        other_box = FILLED.replace("- [x] I checked", "- [ ] I checked").replace(
            "- No documentation changes", "- [x] Ran the link checker\n- No documentation changes")
        problems = check_pr.check_description(other_box)
        self.assertEqual(len(problems), 1)
        self.assertIn("tick", problems[0])
        listed = FILLED.replace("- No documentation changes: focus behaviour is not described anywhere.",
                                "- [x] README.md updated")
        self.assertEqual(check_pr.check_description(listed), [])

    def test_fence_inside_a_comment(self):
        body = (FILLED.replace("CI.\n", "CI.\n\n<!--\n```\n-->\n")
                .replace("Not applicable.\n", "<!-- only a comment -->\n"))
        problems = check_pr.check_description(body)
        self.assertEqual(len(problems), 1)
        self.assertIn('"Performance" is empty', problems[0])

    def test_stray_comment_marker_in_prose_is_text(self):
        body = FILLED.replace("Keeps the focus on the last row.", "Treats a stray <!-- in prose as text.")
        self.assertEqual(check_pr.check_description(body), [])
        later = body.replace("- **Tested?** Yes", "- **Tested?** Yes <!-- note -->")
        self.assertEqual(check_pr.check_description(later), [])

    def test_field_value_on_the_next_line(self):
        body = FILLED.replace("- **Design impact:** No design changes.", "- **Design impact:**\nNo design changes.")
        self.assertEqual(check_pr.check_description(body), [])
        blank = FILLED.replace("- **Design impact:** No design changes.", "- **Design impact:**\n\nNo design changes.")
        self.assertEqual(len(check_pr.check_description(blank)), 1)

    def test_unclosed_comment(self):
        body = FILLED.replace("## Validation", "<!-- draft notes\n\n## Validation")
        problems = check_pr.check_description(body)
        self.assertIn("no closing -->", problems[0])

    def test_comment_markers_in_code_are_text(self):
        body = FILLED.replace("Keeps the focus on the last row.",
                              "An unclosed `<!--` now gets its own message.\n\n```html\n<!-- example\n```")
        self.assertEqual(check_pr.check_description(body), [])

    def test_extra_sections_and_notes_are_allowed(self):
        body = ("> [!NOTE]\n> Follow-up is in another PR.\n\n" + FILLED
                + "\n## Release notes\n\n```text\nRelease-Notes:\n- Fixed focus.\n```\n")
        self.assertEqual(check_pr.check_description(body), [])


if __name__ == "__main__":
    unittest.main()
