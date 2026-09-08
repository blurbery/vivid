#!/usr/bin/env bash
# Resolve the Apple app marketing version from a CI event.
#
# Usage: resolve-marketing-version.sh <event_name> <ref_name> <dispatch_input>
#   workflow_dispatch -> echoes <dispatch_input> verbatim
#   anything else     -> strips the leading 'v', any '+<metadata>' build suffix
#                        (e.g. the +ios / +tvos platform marker), and any
#                        '-<prerelease>' suffix from <ref_name>
#                        (v1.4.0 -> 1.4.0 ; v1.4.0-beta.2 -> 1.4.0 ;
#                         v1.4.0+ios -> 1.4.0 ; v2.0.0-rc.1+tvos -> 2.0.0)
set -euo pipefail

event_name="${1:-}"
ref_name="${2:-}"
dispatch_input="${3:-}"

if [[ "$event_name" == "workflow_dispatch" ]]; then
  version="$dispatch_input"
else
  version="${ref_name#v}"      # strip leading v
  version="${version%%+*}"     # strip +ios / +tvos (semver build metadata)
  version="${version%%-*}"     # strip -beta.N / -rc.N suffix
fi

if [[ -z "$version" ]]; then
  echo "resolve-marketing-version: could not resolve a version from " \
       "event='${event_name}' ref='${ref_name}' input='${dispatch_input}'" >&2
  exit 1
fi

# Reject anything that is not a plain dotted version (e.g. 1.4 or 1.4.0). This
# value is later appended to xcodebuild's xcargs as a shell string, so a value
# containing spaces or shell metacharacters (e.g. "1.4.0 OTHER=1", "1.2$(cmd)")
# must never pass through — it could inject build settings or run commands on
# the signing runner.
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "resolve-marketing-version: '${version}' is not a valid dotted version " \
       "(expected e.g. 1.4.0)" >&2
  exit 1
fi

echo "$version"
