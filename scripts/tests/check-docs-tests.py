#!/usr/bin/env python3
"""Exercise scripts/ci/check-docs.py on small documents, change sets and a scratch repository."""
import contextlib
from importlib.util import module_from_spec, spec_from_file_location
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

root = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("check_docs", root / "scripts/ci/check-docs.py")
check_docs = module_from_spec(spec)
spec.loader.exec_module(check_docs)


def tree(docs, others=()):
    files = set(docs) | set(others)
    folders = set()
    for name in files:
        parts = name.split("/")
        folders.update("/".join(parts[:i]) for i in range(1, len(parts)))
    return files, folders, docs.__getitem__


def tops(folders):
    return {folder for folder in folders if "/" not in folder}


class AnchorTests(unittest.TestCase):
    def test_github_slugs(self):
        self.assertEqual(check_docs.slug("Versioning &amp; Releases"), "versioning--releases")
        self.assertEqual(check_docs.slug("`check-pr.py` runs (fast)"), "check-prpy-runs-fast")
        self.assertEqual(check_docs.slug("Plugins on iPhone, iPad and Apple TV"), "plugins-on-iphone-ipad-and-apple-tv")
        self.assertEqual(check_docs.slug("[Link](x.md) heading"), "link-heading")
        self.assertEqual(check_docs.slug("`Array<T>` and _emphasis_ in snake_case"), "arrayt-and-emphasis-in-snake_case")
        self.assertEqual(check_docs.slug("Logo ![mark](logo.png) guide"), "logo--guide")

    def test_repeats_ids_fences_and_setext(self):
        found = check_docs.anchors(
            "# Notes\n## Notes\n## Notes 1\n<a id=\"Custom\"></a>\n```\n# Not a heading\n```\n"
            "<h1 align=\"center\">Vivid Guide</h1>\n\nSetext title\n===\n\n> ## Quoted\n")
        self.assertEqual(found, {"notes", "notes-1", "notes-1-1", "custom", "vivid-guide", "setext-title", "quoted"})

    def test_rule_after_a_fence_is_not_a_heading(self):
        self.assertEqual(check_docs.anchors("Text\n```\nx\n```\n---\n"), set())

    def test_rules_are_not_headings(self):
        self.assertEqual(check_docs.anchors("Text\n\n---\n\n| a |\n|---|\n- item\n---\n"), set())


class LinkTests(unittest.TestCase):
    def test_good_links_pass(self):
        files, folders, read = tree({
            "README.md": "[Docs](docs/guide.md#setup) [Self](#top) ![Logo](docs/logo.png)\n# Top\n"
                         '<a href="docs/">Folder</a> [Web](https://example.com/x.md#nope)\n'
                         "[ref]: docs/guide.md\n`[not](a-link.md)`\n```\n[nor](this.md)\n```\n"
                         "[^1]: See the guide.\n<!-- [hidden](gone.md) -->\n\\[escaped\\](gone.md)\n"
                         "[Spaced](<docs/my guide.md> 'title') [Encoded](docs/my%20guide.md)\n",
            "docs/guide.md": "## Setup\n[Back](../README.md#top) [Root](/README.md)\n",
            "docs/my guide.md": "Text\n",
            "docs/setup(v2).md": "[Back](../README.md) [Versioned](setup(v2).md)\n",
        }, others={"docs/logo.png"})
        self.assertEqual(check_docs.check_links(files, folders, read), [])

    def test_broken_links_fail(self):
        files, folders, read = tree({
            "README.md": "[Gone](docs/missing.md)\n[Bad anchor](docs/guide.md#nope)\n"
                         '<img src="docs/missing.png">\n[Out](../outside.md)\n[ref]: docs/old.md\n'
                         "[![badge](docs/badge.svg)](docs/guide.md)\n<img src=docs/also-missing.png>\n",
            "docs/guide.md": "## Setup\n",
        })
        problems = check_docs.check_links(files, folders, read)
        self.assertEqual([(doc, line) for doc, line, _ in problems],
                         [("README.md", n) for n in range(1, 8)])


class PathTests(unittest.TestCase):
    def mentions(self, text, others=()):
        files, folders, read = tree({"docs/guide.md": text}, others)
        return check_docs.missing_mentions(files, folders, tops(folders), read)

    def test_existing_and_skipped_paths(self):
        text = ("`scripts/ci/check-pr.py:12` `docs/` `iosApp/Signing/Local.xcconfig` `scripts/ci/*.sh` "
                "`<DerivedData>/x/y` `foo/bar` `.github/pr-assets/` `engine/build/x`\n")
        others = {"scripts/ci/check-pr.py", "iosApp/project.yml", ".github/workflows/x.yml", "engine/pins.ini"}
        self.assertEqual(self.mentions(text, others), [])

    def test_missing_path_is_found(self):
        found = self.mentions("Run `scripts/ci/gone.py` first.\n", others={"scripts/ci/check-pr.py"})
        self.assertEqual([(doc, line, path) for doc, line, path, _ in found], [("docs/guide.md", 1, "scripts/ci/gone.py")])

    def test_missing_docs_paths_are_never_excused(self):
        # .gitignore ignores docs/ apart from the tracked guides, so a missing
        # path there must not count as an ignored local file.
        found = self.mentions("See `docs/gone.md` and `docs/playback/gone.md`.\n")
        self.assertEqual(sorted(path for _, _, path, _ in found), ["docs/gone.md", "docs/playback/gone.md"])

    def test_only_this_change_is_blamed(self):
        mention = ("docs/guide.md", 4, "scripts/ci/gone.py", "Run `scripts/ci/gone.py`.")
        before = {"scripts/ci/gone.py"}
        rewritten = {"docs/guide.md": {4}}
        # Removed by this change: a line it didn't touch is stale; a line it rewrote is deliberate.
        self.assertEqual(len(check_docs.check_paths([mention], before, set(), {})), 1)
        self.assertEqual(check_docs.check_paths([mention], before, set(), rewritten), [])
        # Missing before this change: untouched lines are left alone.
        self.assertEqual(check_docs.check_paths([mention], set(), set(), {}), [])
        # A new line naming a path that doesn't exist fails...
        self.assertEqual(len(check_docs.check_paths([mention], set(), set(), rewritten)), 1)
        # ...unless a doc already named it before the change, such as an edited history line...
        self.assertEqual(check_docs.check_paths([mention], set(), {"scripts/ci/gone.py"}, rewritten), [])
        # ...or the line reads as history.
        history = mention[:3] + ("The previous `scripts/ci/gone.py` was removed.",)
        self.assertEqual(check_docs.check_paths([history], set(), set(), rewritten), [])
        typo = mention[:3] + ("`scripts/ci/gone.py` was added.",)
        self.assertEqual(len(check_docs.check_paths([typo], set(), set(), rewritten)), 1)


class ChangeTests(unittest.TestCase):
    def test_em_dashes_on_added_lines_only(self):
        files, _, read = tree({"docs/guide.md": "fine\nbad \u2014 dash\nold \u2014 dash\nentity &mdash; too\n",
                               "iosApp/iosApp/A.swift": "// \u2014\n"})
        added = {"docs/guide.md": {1, 2, 4}, "iosApp/iosApp/A.swift": {1}}
        problems = check_docs.check_em_dashes(added, files, read)
        self.assertEqual([(path, line) for path, line, _ in problems], [("docs/guide.md", 2), ("docs/guide.md", 4)])

    def test_globs(self):
        self.assertTrue(check_docs.matches("iosApp/iosApp/Networking/EmbyProvider.swift", ["iosApp/iosApp/**/Emby*.swift"]))
        self.assertTrue(check_docs.matches("iosApp/Vivid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                                           ["iosApp/**/Package.resolved"]))
        self.assertTrue(check_docs.matches("iosApp/Vivid.entitlements", ["iosApp/*.entitlements"]))
        self.assertFalse(check_docs.matches("iosApp/TopShelf/TopShelf.entitlements", ["iosApp/*.entitlements"]))
        self.assertFalse(check_docs.matches("iosApp/Tests/EmbyProviderTests.swift", ["iosApp/iosApp/**/Emby*.swift"]))

    def test_doc_map(self):
        emby = {"iosApp/iosApp/Networking/EmbyProvider.swift": "M"}
        problems, _ = check_docs.check_doc_map(emby, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("docs/cores/emby.md", problems[0][2])
        self.assertEqual(check_docs.check_doc_map({**emby, "docs/cores/emby.md": "M"}, set())[0], [])
        skipped, note = check_docs.check_doc_map(emby, {check_docs.SKIP_LABEL})
        self.assertEqual(skipped, [])
        self.assertIn(check_docs.SKIP_LABEL, note)

    def test_doc_map_all_docs_and_excludes(self):
        pin = "iosApp/Vivid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        problems, _ = check_docs.check_doc_map({pin: "M", "THIRD_PARTY_NOTICES.md": "M"}, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("Update iosApp/Resources/OpenSourceLicenses/ in this PR", problems[0][2])
        both = {pin: "M", "THIRD_PARTY_NOTICES.md": "M", "iosApp/Resources/OpenSourceLicenses/licences.json": "M"}
        self.assertEqual(check_docs.check_doc_map(both, set())[0], [])
        self.assertEqual(check_docs.check_doc_map({"scripts/release/notes.test.mjs": "M"}, set())[0], [])
        self.assertEqual(check_docs.check_doc_map({"iosApp/Tests/EmbyProviderTests.swift": "M"}, set())[0], [])

    def test_inventory_rules_fire_on_added_or_removed_files_only(self):
        self.assertEqual(check_docs.check_doc_map({"scripts/ci/check-tmdb-client.sh": "M"}, set())[0], [])
        self.assertEqual(check_docs.check_doc_map({"iosApp/iosApp/Playback/MPV/VividMPVPlayer.swift": "M"}, set())[0], [])
        for status in "AD":
            with self.subTest(status=status):
                self.assertEqual(len(check_docs.check_doc_map({"scripts/ci/check-new.sh": status}, set())[0]), 1)
        # Workflow edits still need the Validation section.
        self.assertEqual(len(check_docs.check_doc_map({".github/workflows/player-regression.yml": "M"}, set())[0]), 1)

    def test_sideload_workflow_takes_either_doc(self):
        changed = {".github/workflows/sideload-ipa.yml": "M", "docs/release/distribution.md": "M"}
        self.assertEqual(check_docs.check_doc_map(changed, set())[0], [])

    def test_player_bridge_files_need_the_architecture_guide(self):
        added = {"iosApp/iosApp/Playback/MPV/NewPart.swift": "A", "docs/cores/player-engine.md": "M"}
        problems, _ = check_docs.check_doc_map(added, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("docs/cores/lucid-engine-architecture.md", problems[0][2])

    def test_privacy_pairs(self):
        problems, _ = check_docs.check_doc_map({"iosApp/iosApp/Shared/Diagnostics/Report.swift": "M"}, set())
        self.assertIn("website/public/privacy.html", problems[0][2])
        problems, _ = check_docs.check_doc_map({"website/public/privacy.html": "M"}, set())
        self.assertIn("IOSSettingsOverview.swift", problems[0][2])
        one = {"website/public/privacy.html": "M", "iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift": "M"}
        problems, _ = check_docs.check_doc_map(one, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("TVSettingsComponents.swift", problems[0][2])
        both = {**one, "iosApp/iosApp/tvOS/Screens/Settings/TVSettingsComponents.swift": "M"}
        self.assertEqual(check_docs.check_doc_map(both, set())[0], [])

    def test_doc_map_targets_exist(self):
        files, _ = check_docs.tree("HEAD")
        self.assertEqual(check_docs.check_doc_map_targets(files), [])
        problems = check_docs.check_doc_map_targets(files - {"docs/plugins.md"})
        self.assertEqual(len(problems), 1)
        self.assertIn("docs/plugins.md", problems[0][2])
        moved = {name for name in files if not name.startswith("iosApp/iosApp/Plugins/")}
        problems = check_docs.check_doc_map_targets(moved)
        self.assertTrue(any("iosApp/iosApp/Plugins/" in problem[2] for problem in problems))


class RepositoryTests(unittest.TestCase):
    """Run the diff helpers against a scratch repository."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.original = check_docs.ROOT
        check_docs.ROOT = Path(self.scratch.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")

    def tearDown(self):
        check_docs.ROOT = self.original
        self.scratch.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=check_docs.ROOT, check=True, capture_output=True)

    def write(self, name, data):
        path = check_docs.ROOT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return check_docs.git("rev-parse", "HEAD").stdout.strip()

    def test_changes_and_added_lines(self):
        self.write("docs/my guide.md", "one\ntwo\nthree\n")
        self.write("docs/café.md", "a\n")
        self.write("old/name.txt", "x\n")
        self.write("data/latin.txt", "caf\xe9\n".encode("latin-1"))
        base = self.commit()
        self.write("docs/my guide.md", "one\n++ b/not-a-header\nthree\nfour\n")
        self.write("docs/café.md", "a\nb\n")
        (check_docs.ROOT / "new").mkdir()
        self.git("mv", "old/name.txt", "new/name.txt")
        self.write("data/latin.txt", "na\xefve\n".encode("latin-1"))
        head = self.commit()
        self.assertEqual(check_docs.changes(base, head), {
            "docs/my guide.md": "M", "docs/café.md": "M", "old/name.txt": "D",
            "new/name.txt": "A", "data/latin.txt": "M"})
        added = check_docs.added_lines(base, head, ["docs/my guide.md", "docs/café.md"])
        self.assertEqual(added, {"docs/my guide.md": {2, 4}, "docs/café.md": {2}})
        self.assertEqual(check_docs.show(head, "data/latin.txt"), "na\ufffdve\n")

    def test_paths_are_literal(self):
        self.write("docs/x.md", "a\n")
        self.write("docs/[x].md", "a\n")
        base = self.commit()
        self.write("docs/x.md", "a\nb\nc\n")
        self.write("docs/[x].md", "a\nb\n")
        head = self.commit()
        self.assertEqual(check_docs.added_lines(base, head, ["docs/[x].md"]), {"docs/[x].md": {2}})

    def run_main(self, *args):
        output = io.StringIO()
        # The scratch repository has none of the docs the real map names.
        with mock.patch.object(sys, "argv", ["check-docs.py", *args]), \
                mock.patch.object(check_docs, "DOC_MAP", []), contextlib.redirect_stdout(output):
            code = check_docs.main()
        return code, output.getvalue()

    def test_links_broken_on_the_base_dont_fail_the_change(self):
        self.write("README.md", "[Old](gone.md)\n")
        base = self.commit()
        self.write("docs/new.md", "Fine.\n")
        head = self.commit()
        code, output = self.run_main("--base", base, "--head", head, "--labels", "[]")
        self.assertEqual(code, 0, output)
        self.assertIn("already on the base branch", output)
        self.write("README.md", "[Old](gone.md)\n[Again](gone.md)\n")
        head = self.commit()
        code, output = self.run_main("--base", base, "--head", head, "--labels", "[]")
        self.assertEqual(code, 1, output)
        self.assertIn("README.md:2:", output)
        self.write("README.md", "[Old](gone.md)\n")
        self.write("docs/new.md", "[New](missing.md)\n")
        head = self.commit()
        code, output = self.run_main("--base", base, "--head", head, "--labels", "[]")
        self.assertEqual(code, 1, output)
        self.assertIn("docs/new.md:1", output)
        # Reported only as an indented note, not as a problem.
        self.assertFalse(any(line.startswith("README.md:1:") for line in output.splitlines()), output)
        self.assertIn("  README.md:1:", output)


if __name__ == "__main__":
    unittest.main()
