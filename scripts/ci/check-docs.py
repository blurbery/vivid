#!/usr/bin/env python3
"""Check that the docs still match the repository and keep up with a PR.

The PR checks workflow runs this on every pull request as
`check-docs.py --base HEAD^1` on the PR's merge commit, with PR_LABELS set
to the PR's labels. Run it locally with no arguments to check the links of
the commit checked out and that the doc map's paths still exist, or with
--base origin/main to check your branch the way CI does (the base is taken
from where your branch left it).

Every Markdown file the repository tracks is checked for:
- relative links and images (Markdown or HTML) whose file or folder is not in
  the repository;
- links to a #heading that the target Markdown file has no heading or id for,
  using GitHub's heading anchors.
External links are not fetched, so the check needs no network.
Every doc, trigger and exclude in the doc map must also still match a tracked
file, with or without a base, so a rename can't switch a rule off.

With a base revision, a broken link that the base already had is reported
but doesn't fail the change, and the change is also checked for:
- repository paths in `inline code` that a doc still names on a line the
  change didn't touch, when the change removed or renamed them;
- repository paths in `inline code` on lines the change wrote, when they
  don't exist, unless the change itself removed them, the same path was
  already named and missing before the change, or the line reads as history
  ("the previous script, now removed").
  Only paths inside a top-level folder are checked (scripts/ci/check-pr.py,
  not package.json or a bare engine/). Ignored local files outside docs/ (for
  example iosApp/Signing/Local.xcconfig) are fine, and paths with wildcards
  or placeholders are not checked;
- em dashes on added lines of Markdown and HTML files and the issue templates;
- the doc map below: when a change touches code that a doc describes, that
  doc must change in the same PR. If nothing the doc says has changed, a
  maintainer adds the docs-not-needed label, which skips the map's rules but
  not the check that its paths exist.
"""
import argparse
from collections import Counter
from dataclasses import dataclass, field
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
SKIP_LABEL = "docs-not-needed"


@dataclass
class Rule:
    name: str
    triggers: list
    docs: list
    why: str
    exclude: list = field(default_factory=list)
    # Every doc must change, rather than any one of them.
    all_docs: bool = False
    # The doc lists these files, so only adding, removing or renaming one
    # needs it updated; editing one doesn't.
    inventory: bool = False


# The doc map. A rule applies when a changed file (for an inventory rule, an
# added or removed one) matches one of its triggers and none of its excludes; it passes when any of its docs changed (or every
# one of them, for all_docs). Globs: * stays within a folder, ** crosses them.
# Keep the table in docs/release/versioning.md (Validation) in step.
DOC_MAP = [
    Rule("Swift package pins",
         ["iosApp/**/Package.resolved"],
         ["THIRD_PARTY_NOTICES.md", "iosApp/Resources/OpenSourceLicenses/**"],
         "THIRD_PARTY_NOTICES.md and the in-app licences list every shipped package and its version.",
         all_docs=True),
    Rule("In-app licences",
         ["iosApp/Resources/OpenSourceLicenses/**"],
         ["THIRD_PARTY_NOTICES.md"],
         "THIRD_PARTY_NOTICES.md and the in-app licences must agree."),
    Rule("What the app sends or stores",
         ["iosApp/iosApp/Shared/Diagnostics/**",
          "iosApp/iosApp/Plugins/MDBListClient.swift",
          "iosApp/iosApp/Plugins/OpenSubtitlesClient.swift",
          "iosApp/iosApp/tvOS/TVTMDbStore.swift",
          "iosApp/iosApp/tvOS/Requests/TVSeerrConnection.swift",
          "iosApp/iosApp/Screens/Detail/TrailerRail.swift",
          "iosApp/**/PrivacyInfo.xcprivacy",
          "iosApp/*.entitlements",
          "diagnostics-relay/worker.mjs"],
         ["website/public/privacy.html"],
         "The privacy policy, and the in-app privacy text that follows it, describe what Vivid "
         "sends to other services and stores."),
    Rule("Privacy policy",
         ["website/public/privacy.html"],
         ["iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift",
          "iosApp/iosApp/tvOS/Screens/Settings/TVSettingsComponents.swift"],
         "The in-app privacy text on both platforms (PhoneVividPrivacyView in IOSSettingsOverview.swift and "
         "TVPrivacyPolicyPage in TVSettingsComponents.swift) has to match the privacy policy.",
         all_docs=True),
    Rule("Emby core",
         ["iosApp/iosApp/**/Emby*.swift"],
         ["docs/cores/emby.md"],
         "docs/cores/emby.md lists what the Emby core implements and what is still unverified."),
    Rule("Jellyfin core",
         ["iosApp/iosApp/**/Jellyfin*.swift"],
         ["docs/cores/jellyfin.md"],
         "docs/cores/jellyfin.md lists what the Jellyfin core implements and what is still unverified."),
    Rule("Silo core",
         ["iosApp/iosApp/**/Silo*.swift", "iosApp/iosApp/Screens/Player/ProtocolV3/**"],
         ["docs/cores/silo.md", "docs/server-connections.md"],
         "docs/cores/silo.md and docs/server-connections.md describe the Silo connection."),
    Rule("Lucid Engine pipeline",
         ["engine/**"],
         ["docs/cores/lucid-engine-build.md", "docs/cores/lucid-engine-architecture.md",
          "docs/playback/lucid-engine-patch-spec.md", "docs/cores/lucid-engine-build-facts.md",
          "docs/cores/lucid-engine-libs-build-facts.md", "docs/cores/player-engine.md"],
         "The Lucid Engine guides describe the pins, patches and build steps in engine/."),
    Rule("Player bridge files",
         ["iosApp/iosApp/Playback/MPV/**"],
         ["docs/cores/lucid-engine-architecture.md"],
         "docs/cores/lucid-engine-architecture.md lists every file in Playback/MPV/.",
         inventory=True),
    Rule("Plugins",
         ["iosApp/iosApp/Plugins/**"],
         ["docs/plugins.md"],
         "docs/plugins.md describes the TMDb, MDBList and OpenSubtitles plugins."),
    Rule("Release tooling",
         ["release.config.mjs", "scripts/release/**", ".github/workflows/release.yml"],
         ["docs/release/versioning.md"],
         "docs/release/versioning.md describes how releases and their notes are made.",
         exclude=["scripts/release/*.test.mjs"]),
    Rule("CI workflows",
         [".github/workflows/**"],
         ["docs/release/versioning.md"],
         "The Validation section of docs/release/versioning.md describes each workflow's triggers and jobs, "
         "or links to the guide that does."),
    Rule("CI scripts",
         ["scripts/ci/**"],
         ["docs/release/versioning.md"],
         "The Validation section of docs/release/versioning.md names every script in scripts/ci/.",
         inventory=True),
    Rule("Diagnostics relay",
         ["diagnostics-relay/**"],
         ["docs/diagnostics-relay.md"],
         "docs/diagnostics-relay.md describes the relay Worker.",
         exclude=["diagnostics-relay/*.test.mjs", "diagnostics-relay/fixtures/**"]),
]

EM_DASH = re.compile(r"\u2014|&mdash;|&#8212;|&#x2014;", re.IGNORECASE)
EM_DASH_FILES = ["**/*.md", "**/*.html", ".github/ISSUE_TEMPLATE/**"]

# A fence opens with three or more backticks or tildes and closes with at
# least as many of the same character and nothing else on the line.
FENCE = re.compile(r"^\s{0,3}(?P<run>`{3,}|~{3,})(?P<rest>.*)$")
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
LINK_TITLE = r"""(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?"""
# A plain destination may hold balanced parentheses, such as setup(v2).md.
LINK_DEST = r"(?:[^()\s]|\([^()\s]*\))+"
MD_LINK = re.compile(r"(?<!\\)!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(?:<([^<>]+)>|(" + LINK_DEST + r"))" + LINK_TITLE + r"\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[(?!\^)[^\]]+\]:\s*(?:<([^<>]+)>|(\S+))")
HTML_ATTR = re.compile(r"""\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""", re.IGNORECASE)
HTML_ID = re.compile(r"""<[a-z][^>]*\b(?:id|name)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s"'>]+))""", re.IGNORECASE)
HEADING = re.compile(r"^\s{0,3}(?:>\s?)*\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
SETEXT = re.compile(r"^\s{0,3}(=+|-+)\s*$")
HTML_HEADING = re.compile(r"<h([1-6])\b[^>]*>(.*?)</h\1>", re.IGNORECASE | re.DOTALL)
SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)
PATH_TOKEN = re.compile(r"^\.?[A-Za-z0-9_][A-Za-z0-9._@+-]*(?:/[A-Za-z0-9_.@+-]+)+/?$")
LINE_SUFFIX = re.compile(r"(?::\d+(?:[-:]\d+)?|#L\d+(?:-L\d+)?)$")
HISTORY = re.compile(r"\b(?:removed|deleted|renamed|retired|replaced|formerly|former|previously|previous|"
                     r"no longer|used to)\b", re.IGNORECASE)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def git(*args, check=True):
    return subprocess.run(["git", "-c", "core.quotePath=false", *args], cwd=ROOT, capture_output=True,
                          encoding="utf-8", errors="replace", check=check)


def show(revision, path):
    """A file's text at a revision; bytes that aren't UTF-8 become U+FFFD."""
    out = subprocess.run(["git", "show", f"{revision}:{path}"], cwd=ROOT, capture_output=True, check=True)
    return out.stdout.decode("utf-8", errors="replace")


def glob_regex(pattern):
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"\Z")


def matches(path, patterns):
    return any(glob_regex(pattern).match(path) for pattern in patterns)


def tree(revision):
    """The files and folders tracked at a revision."""
    names = git("ls-tree", "-r", "-z", "--name-only", revision).stdout.split("\0")
    files = {name for name in names if name}
    folders = set()
    for name in files:
        parts = name.split("/")
        folders.update("/".join(parts[:i]) for i in range(1, len(parts)))
    return files, folders


def text_lines(text):
    """Lines as GitHub numbers them, with HTML comments blanked out."""
    text = COMMENT.sub(lambda comment: "\n" * comment[0].count("\n"), text)
    return text.split("\n")


def prose_lines(text):
    """Yield (line number, line) outside fenced code blocks."""
    fence = None
    for number, line in enumerate(text_lines(text), 1):
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match["run"]
            else:
                yield number, line
        elif (match and match["run"][0] == fence[0] and len(match["run"]) >= len(fence)
              and not match["rest"].strip()):
            fence = None


def heading_text(raw):
    """A heading's rendered text: code spans verbatim, markup removed."""
    parts = []
    last = 0
    for code in INLINE_CODE.finditer(raw):
        parts.append(("text", raw[last:code.start()]))
        parts.append(("code", code[2].strip()))
        last = code.end()
    parts.append(("text", raw[last:]))
    out = ""
    for kind, value in parts:
        if kind == "code":
            out += value
            continue
        value = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", value)
        # Inline [text](url) and reference [text][id] links render as their text.
        value = re.sub(r"\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])", r"\1", value)
        value = re.sub(r"<[^>]+>", "", value)
        value = re.sub(r"(?<!\w)[_*]+|[_*]+(?!\w)", "", value)
        out += html.unescape(value)
    return out


def slugify(text):
    text = re.sub(r"[^\w\- ]", "", text.strip().lower())
    return text.replace(" ", "-")


class Slugger:
    """GitHub's heading ids, including the -1, -2 suffixes for repeats."""

    def __init__(self):
        self.seen = {}

    def slug(self, text):
        base = slugify(text)
        slug = base
        while slug in self.seen:
            self.seen[base] += 1
            slug = f"{base}-{self.seen[base]}"
        self.seen[slug] = 0
        return slug


def slug(text):
    return slugify(heading_text(text))


def anchors(text):
    found = set()
    slugger = Slugger()
    previous = ""
    last = 0
    for number, line in prose_lines(text):
        if number != last + 1:
            # A fenced block came in between, so this line can't underline
            # the text before it.
            previous = ""
        last = number
        heading = None
        atx = HEADING.match(line)
        if atx:
            heading = atx[2]
        elif SETEXT.match(line) and previous.strip() and not re.match(r"^\s*([-*+>|#<]|\d+[.)])", previous):
            heading = previous.strip()
        else:
            tag = HTML_HEADING.search(line)
            if tag:
                heading = tag[2]
        if heading is not None:
            found.add(slugger.slug(heading_text(heading)))
        found.update((a or b or c).lower() for a, b, c in HTML_ID.findall(line))
        previous = "" if heading is not None else line
    return found


def strip_code(line):
    return INLINE_CODE.sub(lambda match: " " * len(match[0]), line)


def link_targets(prose):
    targets = [angle or plain for angle, plain in MD_LINK.findall(prose)]
    # An image inside a link, such as [![badge](a.svg)](b.md), has its own target.
    for text in re.findall(r"\[(!\[[^\]]*\]\([^)]*\))\]", prose):
        targets += [angle or plain for angle, plain in MD_LINK.findall(text)]
    targets += [a or b or c for a, b, c in HTML_ATTR.findall(prose)]
    ref = REF_DEF.match(prose)
    if ref:
        targets.append(ref[1] or ref[2])
    return targets


def check_links(files, folders, read):
    """Broken relative links and anchors in every tracked Markdown file."""
    problems = []
    cache = {}

    def anchor_set(name):
        if name not in cache:
            cache[name] = anchors(read(name))
        return cache[name]

    for doc in sorted(name for name in files if name.endswith(".md")):
        base = Path(doc).parent
        for number, line in prose_lines(read(doc)):
            for target in link_targets(strip_code(line)):
                if not target or SCHEME.match(target) or target.startswith("//"):
                    continue
                path, _, fragment = target.partition("#")
                path = unquote(path.split("?")[0])
                if path:
                    joined = path.lstrip("/") if path.startswith("/") else (base / path).as_posix()
                    resolved = os.path.normpath(joined).rstrip("/")
                    if resolved == ".." or resolved.startswith("../"):
                        problems.append((doc, number, f"The link {target} points outside the repository."))
                        continue
                    if resolved not in files and resolved not in folders and resolved != ".":
                        problems.append((doc, number, f"The link {target} points at {resolved}, which is not in the repository."))
                        continue
                else:
                    resolved = doc
                if fragment and resolved.endswith(".md") and resolved in files:
                    if unquote(fragment).lower() not in anchor_set(resolved):
                        problems.append((doc, number, f"The link {target} names #{fragment}, but {resolved} has no heading or id for it."))
    return problems


def missing_mentions(files, folders, tops, read):
    """Repository paths in inline code that don't exist: (doc, line, path, text)."""
    found = []
    for doc in sorted(name for name in files if name.endswith(".md")):
        for number, line in prose_lines(read(doc)):
            for match in INLINE_CODE.finditer(line):
                token = LINE_SUFFIX.sub("", match[2].strip())
                if not PATH_TOKEN.match(token) or token.split("/")[0] not in tops:
                    continue
                path = token.rstrip("/")
                if path not in files and path not in folders:
                    found.append((doc, number, path, line))
    if not found:
        return []
    # Ask with and without a trailing slash, so folder-only patterns such as
    # engine/build/ count as ignored. docs/ is ignored apart from the files
    # .gitignore lets back in, so a missing path there is never excused.
    asked = sorted({variant for _, _, path, _ in found if not path.startswith("docs/")
                    for variant in (path, path + "/")})
    result = subprocess.run(["git", "check-ignore", "--no-index", "--stdin", "-z"], cwd=ROOT,
                            input="\0".join(asked) + "\0", capture_output=True, encoding="utf-8",
                            errors="replace")
    ignored = set(result.stdout.split("\0"))
    return [mention for mention in found if mention[2] not in ignored and mention[2] + "/" not in ignored]


def changes(base, head):
    """Map each changed path to A (added), D (deleted) or M (modified); renames are D plus A."""
    out = git("diff", "--name-status", "-z", "--no-renames", f"{base}...{head}").stdout.split("\0")
    return {path: status[0] for status, path in zip(out[0::2], out[1::2]) if path}


def added_lines(base, head, paths):
    """Map each of the given paths to the line numbers the change added or rewrote."""
    added = {}
    for path in paths:
        out = git("--literal-pathspecs", "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-renames",
                  f"{base}...{head}", "--", path).stdout
        numbers = set()
        for line in out.split("\n"):
            hunk = HUNK.match(line)
            if hunk:
                start, count = int(hunk[1]), int(hunk[2] if hunk[2] is not None else 1)
                numbers.update(range(start, start + count))
        added[path] = numbers
    return added


def check_paths(mentions, before, already_missing, added):
    """Missing paths this change made stale, or that lines it wrote name.

    before: the files and folders at the base. already_missing: paths some doc
    named, and that didn't exist, before the change.
    """
    problems = []
    for doc, number, path, line in mentions:
        rewritten = number in added.get(doc, ())
        if path in before:
            if not rewritten:
                problems.append((doc, number, f"`{path}` no longer exists: this change removed or renamed it. "
                                              "Update the doc to the new name, or reword the line if it should stay as history."))
        elif rewritten and path not in already_missing and not HISTORY.search(line):
            problems.append((doc, number, f"`{path}` is not a file or folder in the repository. Fix the path, "
                                          "use a `<placeholder>` for an example, or say on the line that it was removed."))
    return problems


def check_em_dashes(added, files, read):
    problems = []
    for path, numbers in sorted(added.items()):
        if not numbers or not matches(path, EM_DASH_FILES) or path not in files:
            continue
        lines = read(path).split("\n")
        for number in sorted(numbers):
            if number <= len(lines) and EM_DASH.search(lines[number - 1]):
                problems.append((path, number, "Added line has an em dash. Use a comma, colon, full stop, "
                                               "brackets or a spaced hyphen instead."))
    return problems


def shown(pattern):
    return pattern[:-2] if pattern.endswith("/**") else pattern


def check_doc_map(changed, labels):
    """changed maps each changed path to its status (A, D or M)."""
    if SKIP_LABEL in labels:
        return [], f'The "{SKIP_LABEL}" label is set, so the doc map is skipped.'
    problems = []
    for rule in DOC_MAP:
        hits = [path for path, status in changed.items()
                if matches(path, rule.triggers) and not matches(path, rule.exclude)
                and (not rule.inventory or status in "AD")]
        if not hits:
            continue
        missing = [doc for doc in rule.docs if not any(matches(path, [doc]) for path in changed)]
        if (not missing) if rule.all_docs else len(missing) < len(rule.docs):
            continue
        which = (" and " if rule.all_docs else " or ").join(shown(doc) for doc in missing)
        listed = ", ".join(hits[:3]) + (f" and {len(hits) - 3} more" if len(hits) > 3 else "")
        verb = "adds, removes or renames" if rule.inventory else "changes"
        problems.append((None, None,
                         f"{rule.name}: this PR {verb} {listed}. {rule.why} Update {which} in this PR. "
                         f'If nothing it says has changed, a maintainer can add the "{SKIP_LABEL}" label.'))
    return problems, None


def check_doc_map_targets(files):
    """Every doc, trigger and exclude the map names must still match a tracked file,
    so renaming a doc or a folder can't silently switch a rule off."""
    problems = []
    for rule in DOC_MAP:
        for pattern in rule.docs + rule.triggers + rule.exclude:
            if not any(matches(name, [pattern]) for name in files):
                problems.append((None, None, f"check-docs.py's doc map ({rule.name}) names {shown(pattern)}, "
                                             "which matches nothing in the repository. Update DOC_MAP."))
    return problems


def escape(value, property=False):
    value = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return value.replace(":", "%3A").replace(",", "%2C") if property else value


def report(problems, notes):
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for path, line, message in problems:
        if annotate:
            location = f" file={escape(path, True)},line={line}," if path else " "
            print(f"::error{location}title=Docs::{escape(message)}")
        else:
            print(f"{path}:{line}: {message}" if path else message)
    for note in notes:
        print(note)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and problems:
        with open(summary, "a") as out:
            out.write("### Docs\n\n")
            out.writelines(f"- {f'`{path}:{line}` ' if path else ''}{message}\n" for path, line, message in problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="revision to compare with, for the change checks (CI passes HEAD^1, the base side of the PR's merge commit)")
    parser.add_argument("--head", default="HEAD", help="revision to check (default: HEAD, the commit checked out)")
    parser.add_argument("--labels", default=os.environ.get("PR_LABELS", "[]"), help="JSON list of PR label names")
    args = parser.parse_args()

    def reader(revision):
        cache = {}

        def read(name):
            if name not in cache:
                cache[name] = show(revision, name)
            return cache[name]
        return read

    read = reader(args.head)
    files, folders = tree(args.head)
    problems = check_doc_map_targets(files)
    links = check_links(files, folders, read)
    notes = []
    if args.base:
        # Where the head left the base, so changes made on the base since
        # then aren't counted as this change's.
        base = git("merge-base", args.base, args.head).stdout.strip()
        base_files, base_folders = tree(base)
        # A broken link that's already on the base came from another change;
        # it's reported, but doesn't fail this one.
        # Counted, so adding another copy of a link that was already broken
        # still fails.
        before = Counter((doc, message) for doc, _, message in check_links(base_files, base_folders, reader(base)))
        inherited = []
        for problem in links:
            key = (problem[0], problem[2])
            if before[key]:
                before[key] -= 1
                inherited.append(problem)
            else:
                problems.append(problem)
        if inherited:
            notes.append(f"{len(inherited)} broken link(s) were already on the base branch, so they don't fail this change:")
            notes += [f"  {doc}:{number}: {message}" for doc, number, message in inherited]
        tops = {name for name in folders | base_folders if "/" not in name}
        mentions = missing_mentions(files, folders, tops, read)
        changed = changes(base, args.head)
        docs = [path for path, status in changed.items()
                if status != "D" and (path.endswith(".md") or matches(path, EM_DASH_FILES))]
        added = added_lines(base, args.head, docs)
        already_missing = {mention[2] for mention in missing_mentions(base_files, base_folders, tops, reader(base))}
        problems += check_paths(mentions, base_files | base_folders, already_missing, added)
        problems += check_em_dashes(added, files, read)
        labels = set(json.loads(args.labels or "[]"))
        doc_map, note = check_doc_map(changed, labels)
        problems += doc_map
        if note:
            notes.append(note)
    else:
        problems += links
        tops = {name for name in folders if "/" not in name}
        mentions = missing_mentions(files, folders, tops, read)
        notes.append(f"No base revision, so only links and the doc map's own paths were checked. "
                     f"{len(mentions)} path mention(s) name paths that don't exist:")
        notes += [f"  {doc}:{number}: {path}" for doc, number, path, _ in mentions]
    report(problems, notes)
    if problems:
        print(f"{len(problems)} docs problem(s).")
        return 1
    print("Docs checks pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
