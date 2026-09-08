#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/resolve-platform.sh"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: ${desc}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
  echo "ok: ${desc}"
}

assert_eq "plain tag -> both"        "both" "$("$script" push             v1.4.0        "")"
assert_eq "prerelease tag -> both"   "both" "$("$script" push             v1.4.0-beta.2 "")"
assert_eq "ios-suffixed tag"         "ios"  "$("$script" push             v1.4.0+ios    "")"
assert_eq "tvos-suffixed tag"        "tvos" "$("$script" push             v2.0.0+tvos   "")"
assert_eq "ios-suffixed prerelease"  "ios"  "$("$script" push             v1.4.0-rc.1+ios "")"
assert_eq "dispatch both"            "both" "$("$script" workflow_dispatch ""           both)"
assert_eq "dispatch ios"             "ios"  "$("$script" workflow_dispatch ""           ios)"
assert_eq "dispatch tvos"            "tvos" "$("$script" workflow_dispatch ""           tvos)"
assert_eq "dispatch empty -> both"   "both" "$("$script" workflow_dispatch ""           "")"

assert_reject() {
  local desc="$1"; shift
  if "$script" "$@" 2>/dev/null; then
    echo "FAIL: ${desc}: expected non-zero exit, got success" >&2
    exit 1
  fi
  echo "ok: ${desc}"
}

assert_reject "invalid dispatch input" workflow_dispatch "" macos

echo "ALL PASS"
