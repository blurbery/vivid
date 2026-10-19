#!/usr/bin/env python3
"""Review a pull request with the Claude API and write the result as JSON.

Run by .github/workflows/claude-code-review.yml after its prepare step has
written .claude-review/ (pr.md, diff.patch, files.txt, comments.md). The
review runs in two passes: one looks for bugs in the code, then one checks
what the PR description, docs and comments claim against the code. Claude
gets read-only tools for reading, searching and listing files, and reports
each finding through a tool as it goes, so a run stopped by its cost limit
or a Claude API error still keeps what it found. This script never writes to
GitHub; the workflow posts the result.

Usage: claude-review.py --pr N --mode full|incremental --from SHA --head SHA
                        --merge-base SHA --out review.json
Environment: ANTHROPIC_API_KEY, optional ANTHROPIC_WORKSPACE_ID,
REVIEW_MODEL, REVIEW_EFFORT, REVIEW_MAX_COST_USD (0 for no limit),
REVIEW_MAX_TURNS (per pass; 100, or 300 without a cost limit).
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

import anthropic

# US$ per million tokens. Thinking is billed as output.
PRICES = {
    "claude-sonnet-5-5": {"input": 2.00, "cache_write": 2.50, "cache_read": 0.20, "output": 10.00},
    "claude-opus-5-5": {"input": 4.00, "cache_write": 5.00, "cache_read": 0.20, "output": 20.00},
}
READ_LIMIT = 400  # lines per read_file call
SEARCH_LIMIT = 80  # matches per search_code call
LIST_LIMIT = 200  # paths per list_files call
DIFF_LIMIT = 250_000  # characters of diff sent up front
CODE_SHARE = 0.7  # of the cost limit the code pass may use, leaving the rest for the claims pass
NUDGE = (
    "Nobody can answer questions during this review. Carry on, and call "
    "finish_review when you're done."
)
UNREAD = (
    "Not finished yet: you haven't read these changed files: {}. Read each one "
    "in context, check the callers of what changed, report anything you "
    "confirm, then call finish_review again."
)

SYSTEM = """You review pull requests for Vivid, an Apple media app written in Swift and SwiftUI. You work on your own: nobody reads your messages until the review is posted, so never stop to ask a question. Use the tools to read code, report each problem with report_finding as soon as you've confirmed it, and end with finish_review.

How to review:
1. Read the PR description and the diff in the first message. Read AGENTS.md for the project's rules when a change might break one.
2. For each changed file, read the changed parts in context with read_file, and use search_code to find the callers of every changed function, type or property and read those call sites. Follow the code far enough to know what actually happens at runtime.
3. Look hard for these kinds of bug:
   - Async races: state read before an `await` and used after it (a copied list being looped over, a flag, a selection) when something else can change it in between.
   - Cancellation: an item cancelled or removed while its request is in flight still completes and acts afterwards, or a retry outlives its cancellation.
   - Account, server or profile switches part-way through: a result started under the old one is written into the new one, or reported as an error there.
   - Error handling: temporary failures (offline, timeouts, 401, 408, 429, 5xx) treated as permanent, or a failed lookup treated as "nothing found" so the code carries on with a wrong default.
   - UI states that miss a case: a button, menu item or message offered or worded wrongly for an item that's waiting, registering, failed, skipped or already downloaded.
   - Data assumptions: missing metadata dropped or defaulted so a label claims something not every item has, unknown values treated as a known value, or a filter applied in one place but not another.
   - Partial data: choices built from what's loaded so far (cached pages, the first season) while the rest is still loading.
   - Documentation that says something the code doesn't do.
   - Also ordinary bugs, crashes, regressions, security problems, private details (keys, tokens, personal names or emails, server addresses, home-folder paths) and clear breaks of the AGENTS.md rules.
4. Before reporting anything, check it again against the code. Trace the real path, confirm the trigger can happen (find a caller that reaches it), and drop the finding if you can't show how it goes wrong. If changed code has no callers at all, report that once as P3 instead of bugs inside it. Skip style nitpicks, requests for more tests and anything the compiler would catch.
5. Existing review comments are in the first message. Don't repeat a finding that's already there, even in different words, and accept a reply explaining why something isn't a problem unless the code clearly shows otherwise. When reviewing new commits, check that each earlier finding the author says is fixed really is fixed, and report a fix that's wrong or incomplete.
6. Report each finding on a line the PR changed, with a priority: P1 for a crash, data loss, a security problem or a core feature broken; P2 for wrong behaviour a user can run into; P3 for minor issues and documentation. In the body, say what goes wrong, the situation that triggers it and how to fix it, in two to four sentences.
7. Call finish_review with a short summary: one line on what you reviewed, then the findings by priority with file names, or one line saying nothing needs fixing. Mention anything you couldn't check.

Be thorough. Read every changed file, tests and docs included, before you finish, and keep going after your first finding: a review that ends after a couple of tool calls has almost always missed something. To keep it quick, make independent reads and searches together in one turn rather than one per turn, and read the parts of large files you need rather than whole files. Write in Australian English without em dashes."""

CLAIMS_SYSTEM = """You check a pull request for Vivid, an Apple media app written in Swift and SwiftUI. Another reviewer has already looked for bugs in the code. Your only job is to check that what the PR says matches what the code does. You work on your own: nobody reads your messages until the review is posted, so never stop to ask a question.

How to check:
1. List the claims: each statement about behaviour in the PR description, in the changed docs and in code comments the PR adds or changes. That includes what the description says the PR fixes or adds.
2. Check each claim against the code with read_file and search_code, following it far enough to know what actually happens. A claim has to hold in every case the code allows, not only the usual one.
3. Report each claim that is wrong or only partly true with report_finding: P2 when the code doesn't do something the PR or docs promise, P3 when only the wording needs fixing. Say what the claim says, what the code actually does and how to fix it, in two to four sentences. Put it on the changed doc or comment line, or, for a promise in the description, on the changed code line it concerns.
4. Check that the PR keeps the existing docs current. Every PR must update the docs its change affects. Search README.md, docs/, THIRD_PARTY_NOTICES.md and website/public/privacy.html for the behaviour, settings, limits, names, endpoints, dependencies and data flows the changed code touches. Report each existing doc statement the change makes untrue, and each new or changed behaviour that a guide covering that area should now mention, as P3 on the changed code line, naming the doc and the line to update. A dependency change also needs THIRD_PARTY_NOTICES.md and the in-app licences, and a change to what the app sends or stores needs the privacy policy and in-app privacy text.
5. Don't report claims that hold, wording preferences or anything already in the existing review comments, which include the code review's findings.
6. Call finish_review with one line on what you checked, then the findings by priority with file names, or one line saying the claims match the code.

Make independent reads and searches together in one turn rather than one per turn. Write in Australian English without em dashes."""

# An added comment line in a diff: Swift (//, /*, *) or Python, YAML and shell (#).
COMMENT_LINE = re.compile(r"^\+[ \t]*(//|/\*|\*|#[ \t])", re.MULTILINE)

TOOLS = [
    {
        "name": "read_file",
        "description": "Read lines from a file in the repository at the PR's head commit. Returns numbered lines, at most 400 per call.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path relative to the repository root."},
                "start_line": {"type": "integer", "description": "First line to read (1-based). Defaults to 1."},
                "end_line": {"type": "integer", "description": "Last line to read. Defaults to start_line + 399."},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "search_code",
        "description": "Search tracked files with git grep (extended regular expression). Returns path:line:text matches, at most 80.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Extended regular expression, for example 'func downloadEpisode\\('."},
                "path": {"type": "string", "description": "Optional directory or glob to limit the search, for example 'iosApp/iosApp/Downloads'."},
            },
            "required": ["pattern"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_files",
        "description": "List tracked files matching a glob, at most 200.",
        "input_schema": {
            "type": "object",
            "properties": {
                "glob": {"type": "string", "description": "Glob such as 'iosApp/iosApp/Downloads/*.swift'."},
            },
            "required": ["glob"],
            "additionalProperties": False,
        },
    },
    {
        "name": "report_finding",
        "description": "Record one confirmed problem. Call it once per finding, as soon as you've checked it.",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File the problem is in, relative to the repository root."},
                "line": {"type": "integer", "description": "A line the PR changed where the problem shows."},
                "priority": {"type": "string", "enum": ["P1", "P2", "P3"]},
                "title": {"type": "string", "description": "One short sentence naming the problem."},
                "body": {"type": "string", "description": "What goes wrong, what triggers it and how to fix it, in two to four sentences."},
            },
            "required": ["path", "line", "priority", "title", "body"],
            "additionalProperties": False,
        },
    },
    {
        "name": "finish_review",
        "description": "End the review with the summary that is posted on the PR.",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "summary": {"type": "string", "description": "One line on what you reviewed, then the findings by priority, or one line saying nothing needs fixing."},
            },
            "required": ["summary"],
            "additionalProperties": False,
        },
    },
]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def safe_path(path):
    """Resolve a repository path, refusing anything outside the checkout or in .git."""
    root = Path.cwd().resolve()
    target = (root / path).resolve()
    if root not in target.parents and target != root:
        raise ValueError(f"{path} is outside the repository")
    if ".git" in target.relative_to(root).parts:
        raise ValueError(f"{path} is inside .git")
    return target


def read_file(path, start_line=1, end_line=None):
    target = safe_path(path)
    if not target.is_file():
        return f"{path} doesn't exist at the head commit."
    lines = target.read_text(errors="replace").splitlines()
    start = max(1, int(start_line))
    end = min(len(lines), int(end_line) if end_line else start + READ_LIMIT - 1, start + READ_LIMIT - 1)
    if start > len(lines):
        return f"{path} has only {len(lines)} lines."
    body = "\n".join(f"{n}\t{lines[n - 1]}" for n in range(start, end + 1))
    more = f" Call again with start_line={end + 1} for more." if end < len(lines) else ""
    return f"{path}, lines {start}-{end} of {len(lines)}.{more}\n{body}"


def search_code(pattern, path=None):
    args = ["grep", "-n", "-I", "-E", "-e", pattern, "--"]
    if path:
        args.append(path)
    result = git(*args)
    if result.returncode not in (0, 1):
        return f"Search failed: {result.stderr.strip()[:300]}"
    matches = result.stdout.splitlines()
    if not matches:
        return "No matches."
    shown = [m[:300] for m in matches[:SEARCH_LIMIT]]
    extra = f"\n({len(matches) - SEARCH_LIMIT} more matches not shown; narrow the search.)" if len(matches) > SEARCH_LIMIT else ""
    return "\n".join(shown) + extra


def list_files(glob):
    result = git("ls-files", "--", glob)
    paths = result.stdout.splitlines()
    if not paths:
        return "No files match."
    extra = f"\n({len(paths) - LIST_LIMIT} more not shown.)" if len(paths) > LIST_LIMIT else ""
    return "\n".join(paths[:LIST_LIMIT]) + extra


def diff_path(row):
    """The new-side path on a diff's +++ line, or None for any other line.

    Git ends the line with a tab when the path contains a space.
    """
    return row[6:].rstrip("\t") if row.startswith("+++ b/") else None


def commentable_lines(merge_base, head):
    """Right-side line numbers GitHub accepts review comments on, per file."""
    diff = git("diff", "--unified=3", "--no-color", "--no-ext-diff", merge_base, head).stdout
    lines, path, new_line = {}, None, 0
    for row in diff.splitlines():
        if row.startswith("+++ "):
            path = diff_path(row)
            if path:
                lines.setdefault(path, set())
        elif row.startswith("@@"):
            match = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", row)
            new_line = int(match.group(1)) if match else 0
        elif path and row.startswith(("+", " ")) and not row.startswith("+++"):
            lines[path].add(new_line)
            new_line += 1
    return lines


def changed_files(diff):
    """Files a diff adds or modifies, leaving out deleted and binary files."""
    return sorted({path for path in map(diff_path, diff.splitlines()) if path})


def cost_of(usage, prices):
    def count(name):
        return getattr(usage, name, None) or 0

    return (
        count("input_tokens") * prices["input"]
        + count("cache_creation_input_tokens") * prices["cache_write"]
        + count("cache_read_input_tokens") * prices["cache_read"]
        + count("output_tokens") * prices["output"]
    ) / 1_000_000


def first_message(args, review_dir, earlier=""):
    def part(name):
        return (review_dir / name).read_text(errors="replace")

    diff = part("diff.patch")
    if len(diff) > DIFF_LIMIT:
        diff = diff[:DIFF_LIMIT] + "\n[The diff is cut off here. Use read_file for the rest of the changed files.]"
    if args.mode == "incremental":
        scope = (
            f"You reviewed this PR before, at commit {args.from_sha}. Review only what changed since then. "
            "The diff below covers just the new commits."
        )
    else:
        scope = "This is the first review of this PR, so review every change it makes."
    comments = part("comments.md") + (f"\n{earlier}" if earlier else "")
    return (
        f"Pull request #{args.pr}. The head commit {args.head} is checked out. {scope}\n\n"
        f"<pr_description>\n{part('pr.md')}\n</pr_description>\n\n"
        f"<changed_files>\n{part('files.txt')}\n</changed_files>\n\n"
        f"<existing_review_comments>\n{comments}\n</existing_review_comments>\n\n"
        f"<diff>\n{diff}\n</diff>"
    )


def run_pass(client, settings, system, opening, to_read, budget):
    """Run one review conversation until finish_review, the budget or the turn limit."""
    model, effort, prices, max_turns = settings
    messages = [{"role": "user", "content": opening}]
    # The first finish_review is refused while files in to_read are unread,
    # which sends the pass back to read them. A second one is accepted.
    run = {"findings": [], "summary": None, "stopped": None, "turns": 0, "tool_calls": 0, "cost": 0.0, "files_read": set()}
    sent_back, nudges = False, 0

    while run["summary"] is None:
        if run["cost"] >= budget:
            run["stopped"] = "cost"
            break
        if run["turns"] >= max_turns:
            run["stopped"] = "turns"
            break
        try:
            response = client.beta.messages.create(
                model=model,
                max_tokens=16000,
                system=system,
                tools=TOOLS,
                messages=messages,
                output_config={"effort": effort},
                cache_control={"type": "ephemeral"},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            )
        except (anthropic.APIStatusError, anthropic.APIConnectionError) as error:
            # A long run can outgrow the context window or hit an outage late
            # on. Stop here and keep the findings rather than losing them all.
            print(f"::warning::Claude API error on turn {run['turns'] + 1}: {error}")
            run["stopped"] = "error"
            break
        run["turns"] += 1
        run["cost"] += cost_of(response.usage, prices)
        if response.stop_reason == "max_tokens":
            print(f"::warning::Turn {run['turns']} hit the output token limit.")
        if response.stop_reason == "refusal":
            run["stopped"] = "refusal"
            break
        messages.append({"role": "assistant", "content": response.content})

        calls = [block for block in response.content if block.type == "tool_use"]
        if not calls:
            if nudges < 2:
                nudges += 1
                messages.append({"role": "user", "content": NUDGE})
                continue
            text = "\n".join(block.text for block in response.content if block.type == "text").strip()
            run["summary"] = text or "The review ended without a summary."
            run["stopped"] = "no_summary"
            break

        run["tool_calls"] += len(calls)
        results = []
        for call in calls:
            data = call.input or {}
            try:
                if call.name == "read_file":
                    output = read_file(data["path"], data.get("start_line", 1), data.get("end_line"))
                    run["files_read"].add(os.path.normpath(data["path"]))
                elif call.name == "search_code":
                    output = search_code(data["pattern"], data.get("path"))
                elif call.name == "list_files":
                    output = list_files(data["glob"])
                elif call.name == "report_finding":
                    run["findings"].append({key: data[key] for key in ("path", "line", "priority", "title", "body")})
                    output = "Recorded."
                elif call.name == "finish_review":
                    unread = [path for path in to_read if path not in run["files_read"]]
                    if unread and not sent_back:
                        sent_back = True
                        results.append({"type": "tool_result", "tool_use_id": call.id, "content": UNREAD.format(", ".join(unread)), "is_error": True})
                        continue
                    run["summary"] = data["summary"]
                    output = "Review finished."
                else:
                    output = f"Unknown tool {call.name}."
                results.append({"type": "tool_result", "tool_use_id": call.id, "content": output})
            except (KeyError, TypeError, ValueError, OSError) as error:
                results.append({"type": "tool_result", "tool_use_id": call.id, "content": f"Error: {error}", "is_error": True})
        messages.append({"role": "user", "content": results})
    return run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pr", required=True)
    parser.add_argument("--mode", choices=["full", "incremental"], required=True)
    parser.add_argument("--from", dest="from_sha", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--merge-base", required=True)
    parser.add_argument("--review-dir", default=".claude-review")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    model = os.environ.get("REVIEW_MODEL", "claude-sonnet-5-5")
    effort = os.environ.get("REVIEW_EFFORT", "low")
    # A cost limit of 0 means none. The turn limit still ends a run that loops.
    max_cost = float(os.environ.get("REVIEW_MAX_COST_USD", "1.50"))
    if max_cost <= 0:
        max_cost = math.inf
    max_turns = int(os.environ.get("REVIEW_MAX_TURNS", "100" if math.isfinite(max_cost) else "300"))
    settings = (model, effort, PRICES[model], max_turns)
    workspace = os.environ.get("ANTHROPIC_WORKSPACE_ID")
    client = anthropic.Anthropic(default_headers={"anthropic-workspace-id": workspace} if workspace else None)

    review_dir = Path(args.review_dir)
    diff = (review_dir / "diff.patch").read_text(errors="replace")
    to_read = changed_files(diff)
    code = run_pass(client, settings, SYSTEM, first_message(args, review_dir), to_read, max_cost * CODE_SHARE)
    passes = [("code", code)]
    # The claims pass checks what the PR says against the code, with whatever
    # the code pass left of the limit. New commits that touch no docs or
    # comments add no claims to check.
    docs = [path for path in to_read if path.endswith(".md")]
    if code["stopped"] != "refusal" and (args.mode == "full" or docs or COMMENT_LINE.search(diff)):
        earlier = "\n".join(f"- Code review finding on {f['path']}:{f['line']}: {f['title']}" for f in code["findings"])
        opening = first_message(args, review_dir, earlier)
        passes.append(("claims", run_pass(client, settings, CLAIMS_SYSTEM, opening, docs, max_cost - code["cost"])))

    findings = [finding for _, run in passes for finding in run["findings"]]
    allowed = commentable_lines(args.merge_base, args.head)
    for finding in findings:
        finding["inline"] = finding["line"] in allowed.get(finding["path"], set())
    files_read = set().union(*(run["files_read"] for _, run in passes))
    summaries = [run["summary"] for _, run in passes if run["summary"]]
    cost = sum(run["cost"] for _, run in passes)
    # A pass stopped by a limit, a refusal or an error outranks one that only
    # ended without a summary, so the workflow knows the review is incomplete.
    stops = [run["stopped"] for _, run in passes if run["stopped"]]
    stopped = next((stop for stop in stops if stop != "no_summary"), next(iter(stops), None))

    result = {
        "summary": "\n\n".join(summaries) or "The review stopped before Claude wrote a summary.",
        "findings": findings,
        "stopped": stopped,
        "turns": sum(run["turns"] for _, run in passes),
        "tool_calls": sum(run["tool_calls"] for _, run in passes),
        "files_read": sorted(files_read),
        "changed_files_unread": [path for path in to_read if path not in files_read],
        "passes": [
            {"name": name, "findings": len(run["findings"]), "turns": run["turns"], "cost_usd": round(run["cost"], 4), "stopped": run["stopped"]}
            for name, run in passes
        ],
        "cost_usd": round(cost, 4),
        "model": model,
        "effort": effort,
    }
    if result["turns"] == 0:
        # The API never answered (a bad key or no credit), so there's nothing to post.
        print("Claude API error before the review started.", file=sys.stderr)
        sys.exit(1)
    Path(args.out).write_text(json.dumps(result, indent=2))
    for name, run in passes:
        print(f"{name} pass: {len(run['findings'])} findings, {run['turns']} turns, {run['tool_calls']} tool calls, about US${run['cost']:.2f}")
    read_count = len(to_read) - len(result["changed_files_unread"])
    print(
        f"{len(findings)} findings, {result['turns']} turns, read {read_count} of {len(to_read)} changed files, "
        f"about US${cost:.2f}, stopped: {result['stopped'] or 'finished'}"
    )


if __name__ == "__main__":
    try:
        main()
    except anthropic.APIStatusError as error:
        print(f"Claude API error {error.status_code}: {error.message}", file=sys.stderr)
        sys.exit(1)
    except anthropic.APIConnectionError as error:
        print(f"Couldn't reach the Claude API: {error}", file=sys.stderr)
        sys.exit(1)
