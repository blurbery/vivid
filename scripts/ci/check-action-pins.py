#!/usr/bin/env python3
"""Fail when a workflow uses an action or reusable workflow by tag or branch.

A tag such as @v4 can be moved to different code after review. Every `uses:`
that names another repository's action or reusable workflow must name a full
commit SHA, with the version it was taken from in a trailing comment, for
example:

    uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

Dependabot updates the SHA and the comment together. Local actions (./...)
and docker:// images are not checked.

Each workflow in .github/workflows/ is parsed as YAML with Ruby's YAML
library, which GitHub's Ubuntu and macOS runners include, so quoting, flow
mappings, explicit keys and block scalars are read exactly as GitHub reads
them. The places GitHub takes an action from are checked: jobs.<id>.uses (a
reusable workflow) and jobs.<id>.steps[*].uses. The parser gives each value's
line and column, so problems are reported on the right line, and the version
comment, which YAML drops, is read from the rest of the line the value ends
on. Run with no arguments.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PINNED = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
# Walks Psych's node tree, so each value comes with its own line and column:
# jobs.<id>.uses, and uses in each mapping of jobs.<id>.steps.
WALK = r"""
require 'yaml'
require 'json'

def pairs(node)
  node.is_a?(Psych::Nodes::Mapping) ? node.children.each_slice(2).to_a : []
end

def name(node)
  node.is_a?(Psych::Nodes::Scalar) ? node.value : nil
end

def entry(where, node)
  found = { where: where, line: node.start_line + 1 }
  if node.is_a?(Psych::Nodes::Scalar)
    found.merge(value: node.value, end_line: node.end_line, end_column: node.end_column)
  else
    found.merge(value: nil)
  end
end

found = []
document = YAML.parse(STDIN.read)
root = document && document.root
pairs(root).each do |key, jobs|
  next unless name(key) == 'jobs'
  pairs(jobs).each do |job_key, job|
    id = name(job_key)
    pairs(job).each do |field, value|
      case name(field)
      when 'uses'
        found << entry("jobs.#{id}.uses", value)
      when 'steps'
        next unless value.is_a?(Psych::Nodes::Sequence)
        value.children.each_with_index do |step, index|
          pairs(step).each do |step_key, step_value|
            found << entry("jobs.#{id}.steps[#{index}].uses", step_value) if name(step_key) == 'uses'
          end
        end
      end
    end
  end
end
puts JSON.generate(found)
"""


def uses_entries(text):
    """Each uses: GitHub reads, with its value and position, from Ruby's YAML parser."""
    result = subprocess.run(["ruby", "-e", WALK], input=text, capture_output=True, text=True)
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        raise ValueError(lines[-1] if lines else "not valid YAML")
    return json.loads(result.stdout)


def problems_in(text):
    """(line number or None, message) for each uses: that isn't pinned with a version comment."""
    try:
        entries = uses_entries(text)
    except ValueError as error:
        return [(None, f"The workflow couldn't be read as YAML: {error}")]
    lines = text.splitlines()
    problems = []
    for entry in entries:
        where, value, line = entry["where"], entry["value"], entry["line"]
        if not isinstance(value, str) or not value.strip():
            problems.append((line, f"{where} has no action."))
            continue
        action = value.strip()
        if action.startswith(("./", "docker://")):
            continue
        if not PINNED.match(action):
            problems.append((line, f"{action} ({where}) is not pinned to a commit SHA. "
                                   "Use the full SHA, with the version in a trailing comment."))
            continue
        # YAML drops comments, so read the rest of the line the value ends on.
        end_line, end_column = entry["end_line"], entry["end_column"]
        rest = lines[end_line][end_column:] if end_line < len(lines) else ""
        if not re.search(r"(^|\s)#\s*\S", rest):
            problems.append((line, f"{action} ({where}) has no version comment on its line. "
                                   "Add the version it was taken from, for example # v4."))
    return problems


def main():
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    failed = False
    for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        path = workflow.relative_to(ROOT).as_posix()
        for number, message in problems_in(workflow.read_text(encoding="utf-8", errors="replace")):
            failed = True
            if annotate:
                location = f"file={path},line={number}" if number else f"file={path}"
                print(f"::error {location},title=Action pins::{message}")
            else:
                print(f"{path}:{number or 1}: {message}")
    if failed:
        return 1
    print("Every workflow action is pinned to a commit SHA with a version comment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
