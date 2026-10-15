#!/usr/bin/env python3
"""Check a pull request's title, branch name and description.

The PR checks workflow runs this on every pull request event, passing the PR
through environment variables. Run it locally with the same variables, or
with the options below:

    python3 scripts/ci/check-pr.py --title "fix: keep focus on the row" \
        --branch fix/row-focus --body-file body.md --files changed.txt

- Pull requests are squash-merged and the PR title becomes the commit subject
  that semantic-release reads, so the title must be a Conventional Commit.
- A PR that changes nothing shipped in the app (only docs, CI, tooling,
  tests, the website, the diagnostics relay or the engine pipeline) is
  housekeeping and needs [skip release] in its title.
- Branches in blurbery/vivid are named <type>/<short-description>. Branches
  in forks belong to their contributors and are not checked.
- The description must complete every section of the PR template. On a
  draft PR, missing sections are warnings until it is marked ready.
- Bot PRs, such as Dependabot's, skip the branch and description checks.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / ".github/PULL_REQUEST_TEMPLATE.md"

# Conventional Commit types this repository uses. The release rules are in
# docs/release/versioning.md: feat bumps minor, a ! after the type or a
# BREAKING CHANGE: footer bumps major, and everything else bumps patch.
TYPES = ("feat", "fix", "perf", "docs", "style", "refactor", "test", "build",
         "ci", "chore", "revert")
TITLE = re.compile(r"^(?P<type>[A-Za-z]+)(?:\((?P<scope>[^()]*)\))?(?P<breaking>!)?: (?P<subject>\S.*)$")
SKIP_RELEASE = re.compile(r"\[skip release\]", re.IGNORECASE)

# Branch prefixes: the Conventional Commit types, plus release/ for an App
# Store hotfix branch and experiment/ for long-running engine work.
BRANCH_PREFIXES = TYPES + ("release", "experiment")
BRANCH = re.compile(r"^(?P<prefix>[^/]+)/[A-Za-z0-9][A-Za-z0-9._/-]*$")
# The branch GitHub's Revert button creates, such as revert-148-fix/thing.
REVERT_BRANCH = re.compile(r"^revert-\d+-")

# Template sections, matched on the start of each "## " heading so a small
# rewording still counts. Each value is the name used in messages.
SECTIONS = {
    "problem": "Problem and reproduction",
    "implementation": "Implementation and impact",
    "validation": "Validation",
    "performance": "Performance",
    "testing": "Testing status",
    "design": "Design impact and approval",
    "documentation": "Documentation impact",
    "ai disclosure": "AI disclosure",
}
# Fields that must be present and filled in. Testing status may instead be
# one sentence with no fields, such as "Not applicable, documentation-only
# change."; once it uses any field, Tested? is required.
REQUIRED_FIELDS = {
    "testing": ("Tested?",),
    "design": ("Design impact", "Approval from blurbery"),
}
FIELDS_OPTIONAL = {"testing"}
# A list item that starts with a bold label: "- **Design impact:** None".
# The value can also sit on indented lines below it.
FIELD = re.compile(r"^(?P<indent>\s*)(?:[-*+]|\d+[.)])\s+\*\*(?P<label>[^*]+?)\*\*\s*(?P<value>.*)$")
TICKED = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\]\s+\S")
HEADING = re.compile(r"^\s{0,3}##\s+(?P<name>.+?)\s*#*\s*$")
TITLE_HEADING = re.compile(r"^\s{0,3}#\s")
FENCE = re.compile(r"^\s{0,3}(```|~~~)")
# Review bots that append their own block to the description.
GENERATED = re.compile(r"<!--\s*This is an auto-generated.*?-->.*?<!--\s*End of auto-generated.*?-->",
                       re.DOTALL | re.IGNORECASE)
COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
CLOSED_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
INLINE_CODE = re.compile(r"(`+)(.+?)\1")


def ships_in_app(path):
    """Whether a changed path ends up in the iOS or tvOS app.

    scripts/xcode/ holds build phases of both app targets.
    """
    return (path.startswith(("iosApp/", "scripts/xcode/"))
            and not path.startswith("iosApp/Tests/"))


def check_title(title, files):
    problems = []
    match = TITLE.match(title)
    if not match:
        hint = (' For a revert, retitle it "revert: <what the reverted PR did>".'
                if title.startswith('Revert "') else "")
        problems.append(
            f'The title "{title}" is not a Conventional Commit. Use '
            '"<type>: <summary>" or "<type>(<scope>): <summary>", for example '
            f'"fix: keep focus on the last row". It becomes the commit subject on main.{hint}')
    elif match["type"] not in TYPES:
        hint = " Types are lower case." if match["type"].lower() in TYPES else ""
        problems.append(
            f'The title type "{match["type"]}" is not one of: {", ".join(TYPES)}.{hint}')
    if files is not None and not any(ships_in_app(path) for path in files) and not SKIP_RELEASE.search(title):
        problems.append(
            "Nothing in this PR ships in the app (every change is outside iosApp/ "
            "or under iosApp/Tests/), so it is documentation or housekeeping. Add "
            '"[skip release]" to the end of the title so merging it does not '
            "publish a release.")
    return problems


def check_branch(branch):
    match = BRANCH.match(branch)
    if match and match["prefix"] in BRANCH_PREFIXES or REVERT_BRANCH.match(branch):
        return []
    return [
        f'The branch "{branch}" does not follow <type>/<short-description>, where '
        f'<type> is one of: {", ".join(BRANCH_PREFIXES)}. Rename it on GitHub '
        "(the PR follows the rename) or locally with git branch -m, for example "
        "fix/row-focus."]


def protect_code(text):
    """Neutralise <!-- inside code spans and fenced blocks, which GitHub shows as text."""
    lines = []
    fence = None
    for line in text.split("\n"):
        marker = FENCE.match(line)
        if marker:
            fence = marker[1] if fence is None else (None if line.strip().startswith(fence) else fence)
            lines.append(line)
        elif fence is not None:
            lines.append(line.replace("<!--", "&lt;!--"))
        else:
            lines.append(INLINE_CODE.sub(lambda code: code[0].replace("<!--", "&lt;!--"), line))
    return "\n".join(lines)


def normalise(body):
    body = (body or "").replace("\r\n", "\n").replace("\r", "\n")
    return protect_code(GENERATED.sub("", body))


def clean(body):
    return COMMENT.sub("", normalise(body))


def section_key(heading):
    """The template section a heading names, ignoring case, bold and emoji."""
    name = re.sub(r"[^a-z0-9 ]+", "", heading.lower()).strip()
    return next((key for key in SECTIONS if name.startswith(key)), None)


def sections(text):
    """Map each template section key to the lines under its heading.

    Headings inside fenced code blocks don't start or end a section.
    """
    found = {}
    current = None
    fence = None
    for line in text.split("\n"):
        marker = FENCE.match(line)
        if marker:
            fence = marker[1] if fence is None else (None if line.strip().startswith(fence) else fence)
        elif fence is None:
            heading = HEADING.match(line)
            if heading:
                current = section_key(heading["name"])
                if current is not None:
                    found.setdefault(current, [])
                continue
            if TITLE_HEADING.match(line):
                current = None
                continue
        if current is not None:
            found[current].append(line)
    return found


def fields_of(lines):
    """Map each bold field label to its value.

    The value is the text after the label, or else the indented lines below
    it, such as sub-bullets.
    """
    fields = {}
    waiting = None
    for line in lines:
        if not line.strip():
            continue
        field = FIELD.match(line)
        if field and not field["indent"]:
            label = field["label"].strip().rstrip(":").strip()
            fields[label] = field["value"].lstrip(":").strip()
            waiting = None if fields[label] else label
        elif waiting and line[:1] in (" ", "\t"):
            fields[waiting] = line.strip()
            waiting = None
        else:
            waiting = None
    return fields


def template_lines():
    """The scaffolding lines of each template section, which don't count as content."""
    if not TEMPLATE.exists():
        return {}
    return {key: {line.strip() for line in lines if line.strip()}
            for key, lines in sections(clean(TEMPLATE.read_text())).items()}


def display(label):
    return label if label.endswith("?") else label + ":"


def check_description(body):
    found = sections(clean(body))
    scaffolding = template_lines()
    problems = []
    if "<!--" in CLOSED_COMMENT.sub("", normalise(body)):
        problems.append("The description has a <!-- comment with no closing -->, which hides "
                        "everything after it. Close it or remove it.")
    for key, name in SECTIONS.items():
        if key not in found:
            problems.append(f'The description has no "## {name}" section. Use the PR template and complete every section.')
            continue
        lines = [line.strip() for line in found[key] if line.strip()]
        content = [line for line in lines if line not in scaffolding.get(key, set())]
        fields = fields_of(found[key])
        if not content:
            problems.append(f'"{name}" is empty. Fill it in, or say why it does not apply.')
            continue
        for label in REQUIRED_FIELDS.get(key, ()):
            if label not in fields:
                if key not in FIELDS_OPTIONAL or fields:
                    problems.append(f'"{name}" has no **{display(label)}** line. Keep the template\'s field and fill it in.')
            elif not fields[label]:
                problems.append(f'"{name}" leaves **{display(label)}** blank.')
        if key == "ai disclosure":
            blank = [label for label, value in fields.items() if not value]
            if blank:
                problems.append(
                    "AI disclosure leaves " + ", ".join(f"**{display(label)}**" for label in blank)
                    + " blank. Fill in every field, or replace them with one accurate sentence.")
        if key == "documentation":
            if not any(TICKED.match(line) for line in lines):
                problems.append(
                    'Documentation impact: tick "I checked the docs this change affects" '
                    "once you have checked them.")
            elif not [line for line in content if not TICKED.match(line)]:
                problems.append(
                    "Documentation impact: list the docs this PR updates, or write "
                    '"No documentation changes" and why.')
    return problems


def changed_files(base, head):
    # --no-renames lists both sides of a move, so moving a file out of
    # iosApp/ still counts as an app change.
    result = subprocess.run(["git", "diff", "--name-only", "--no-renames", f"{base}...{head}"],
                            cwd=ROOT, capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def escape(message):
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main():
    env = os.environ
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--title", default=env.get("PR_TITLE", ""))
    parser.add_argument("--branch", default=env.get("PR_BRANCH", ""))
    parser.add_argument("--body-file", help="PR description (default: $PR_BODY)")
    parser.add_argument("--files", help="file listing the changed paths, one per line (default: git diff $BASE_SHA...$HEAD_SHA)")
    parser.add_argument("--fork", action="store_true", default=env.get("PR_IS_FORK") == "true")
    parser.add_argument("--bot", action="store_true", default=env.get("PR_AUTHOR_TYPE") == "Bot")
    parser.add_argument("--draft", action="store_true", default=env.get("PR_DRAFT") == "true")
    args = parser.parse_args()

    body = Path(args.body_file).read_text() if args.body_file else env.get("PR_BODY", "")
    if args.files:
        files = [line.strip() for line in Path(args.files).read_text().splitlines() if line.strip()]
    elif env.get("BASE_SHA") and env.get("HEAD_SHA"):
        files = changed_files(env["BASE_SHA"], env["HEAD_SHA"])
    else:
        files = None
        print("No changed files given, so the [skip release] rule was not checked.")

    errors = check_title(args.title.strip(), files)
    warnings = []
    if args.bot:
        print("Bot PR: the branch and description checks are skipped.")
    else:
        if not args.fork:
            errors += check_branch(args.branch)
        if args.draft:
            warnings = check_description(body)
        else:
            errors += check_description(body)

    annotate = env.get("GITHUB_ACTIONS") == "true"
    for level, items in (("error", errors), ("warning", warnings)):
        for item in items:
            print(f"::{level} title=PR checks::{escape(item)}" if annotate else f"{level}: {item}")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            if errors or warnings:
                out.write("### PR title, branch and description\n\n")
                out.writelines(f"- {item}\n" for item in errors)
                out.writelines(f"- Draft, not yet required: {item}\n" for item in warnings)
                out.write("\nEdit the PR title or description and this check runs again by itself.\n")
            else:
                out.write("The PR title, branch and description pass.\n")
    if not errors:
        print("The PR title, branch and description pass." + (" Warnings above are for a draft." if warnings else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
