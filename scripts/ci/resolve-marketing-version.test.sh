#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/resolve-marketing-version.sh"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: ${desc}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
  echo "ok: ${desc}"
}

assert_eq "final tag"      "1.4.0" "$("$script" push          v1.4.0        "")"
assert_eq "prerelease tag" "1.4.0" "$("$script" push          v1.4.0-beta.2 "")"
assert_eq "rc tag"         "2.0.0" "$("$script" push          v2.0.0-rc.1   "")"
assert_eq "ios-suffixed"   "1.4.0" "$("$script" push          v1.4.0+ios    "")"
assert_eq "tvos-suffixed"  "1.4.0" "$("$script" push          v1.4.0+tvos   "")"
assert_eq "prerelease+meta" "2.0.0" "$("$script" push         v2.0.0-rc.1+tvos "")"
assert_eq "dispatch input" "1.4.0" "$("$script" workflow_dispatch ""        1.4.0)"

assert_reject() {
  local desc="$1"; shift
  if "$script" "$@" 2>/dev/null; then
    echo "FAIL: ${desc}: expected non-zero exit, got success" >&2
    exit 1
  fi
  echo "ok: ${desc}"
}

assert_reject "empty result"               push             ""                       ""
assert_reject "command-substitution tag"   push             'v1.2.3$(whoami)'        ""
assert_reject "xcarg injection via dispatch" workflow_dispatch ""                     "1.4.0 CURRENT_PROJECT_VERSION=999"
assert_reject "space in dispatch input"    workflow_dispatch ""                       "1.4.0 OTHER=1"
assert_reject "non-numeric tag"            push             vfoo                     ""
assert_reject "leading-v only"             push             v                        ""

echo "ALL PASS"
