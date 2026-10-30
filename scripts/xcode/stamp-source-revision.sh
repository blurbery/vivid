#!/usr/bin/env bash
# Records the exact source commit in the built app's Info.plist as
# VividSourceRevision, so About and Open Source Licences can point every
# build at the source it came from (GPLv3 corresponding source).
#
# Runs as the last build phase of the Vivid and VividTV app targets, after
# Info.plist processing and before code signing. Builds with uncommitted
# changes to tracked files get a "-modified" suffix, because their source
# isn't on GitHub. Package.resolved is ignored: Xcode rewrites it when the
# project is regenerated, and the project specs pin the same revisions.
# Outside a Git checkout the key is left empty.
set -euo pipefail

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
revision=""
if commit="$(git -C "${SRCROOT:?}" rev-parse --verify HEAD 2>/dev/null)"; then
  revision="$commit"
  if [ -n "$(git -C "$SRCROOT" status --porcelain --untracked-files=no -- ':(top)' ':(top,exclude)**/Package.resolved' 2>/dev/null)" ]; then
    revision="$commit-modified"
  fi
fi

if /usr/libexec/PlistBuddy -c "Print :VividSourceRevision" "$plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :VividSourceRevision $revision" "$plist"
else
  /usr/libexec/PlistBuddy -c "Add :VividSourceRevision string $revision" "$plist"
fi
echo "VividSourceRevision: ${revision:-unknown}"

# The declared output lets the build system order this phase.
[ -z "${DERIVED_FILE_DIR:-}" ] || { mkdir -p "$DERIVED_FILE_DIR"; echo "$revision" > "$DERIVED_FILE_DIR/source-revision-stamp"; }

# A distributed build must map to published source. Release builds warn,
# never fail, when this one doesn't: uncommitted changes, or a commit that
# no fetched origin branch contains yet.
if [ "${CONFIGURATION:-}" = "Release" ]; then
  if [ -z "$revision" ]; then
    echo "warning: This Release build isn't from a Git checkout, so it has no source revision. Distributed builds must map to published source (GPL corresponding source)."
  elif [ "${revision%-modified}" != "$revision" ]; then
    echo "warning: This Release build has uncommitted changes ($revision). Distributed builds must map to published source (GPL corresponding source), so commit and push first."
  else
    published="$(git -C "$SRCROOT" branch -r --list 'origin/*' --contains "$commit" 2>/dev/null || true)"
    if [ -z "$published" ]; then
      echo "warning: This Release build's commit $commit isn't on any origin branch (fetch if it was pushed from elsewhere). Distributed builds must map to published source (GPL corresponding source), so push it first."
    fi
  fi
fi
