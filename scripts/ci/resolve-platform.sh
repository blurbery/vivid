#!/usr/bin/env bash
# Resolve which Apple platform(s) a build targets.
#
# Usage: resolve-platform.sh <event_name> <ref_name> <dispatch_input>
#   workflow_dispatch -> uses <dispatch_input> (both|ios|tvos; empty -> both)
#   tag push          -> *+ios  -> ios   (e.g. v1.4.0+ios, v1.4.0-beta.1+ios)
#                        *+tvos -> tvos  (e.g. v1.4.0+tvos)
#                        v*     -> both  (no +platform metadata)
# Output is always one of: both | ios | tvos (invalid input exits non-zero).
set -euo pipefail

event_name="${1:-}"
ref_name="${2:-}"
dispatch_input="${3:-}"

if [[ "$event_name" == "workflow_dispatch" ]]; then
  platform="${dispatch_input:-both}"
else
  case "$ref_name" in
    *+ios)  platform="ios" ;;
    *+tvos) platform="tvos" ;;
    *)      platform="both" ;;   # plain v* (no +platform suffix) -> both
  esac
fi

case "$platform" in
  both|ios|tvos) echo "$platform" ;;
  *)
    echo "resolve-platform: invalid platform '${platform}' " \
         "(event='${event_name}' ref='${ref_name}' input='${dispatch_input}')" >&2
    exit 1
    ;;
esac
