#!/usr/bin/env bash
# Updates iosApp/Resources/Localizable.xcstrings with every string the Swift
# compiler finds in the Vivid (iOS) and VividTV (tvOS) app targets.
#
# Xcode can only sync a String Catalog with the platform it just built, and
# the two apps come from separate XcodeGen specs, so an ordinary build would
# delete every untranslated string only the other platform uses. This script
# builds both for the simulator with compiler extraction on, syncs their
# strings in one pass, then marks every entry manual so later Xcode builds
# leave the catalog alone. Strings the code no longer uses are removed, or
# marked stale if they have translations.
#
# Usage: scripts/l10n/sync-string-catalog.sh [--no-build] [derived-data-path]
#   --no-build  Sync from the last builds in derived-data-path.
# The default derived data path is kept between runs so later builds are
# incremental. Use a fresh one to drop strings from deleted Swift files.
set -euo pipefail

build=1
if [ "${1:-}" = "--no-build" ]; then
  build=0
  shift
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="$repo/iosApp"
catalog="$app/Resources/Localizable.xcstrings"
derived="${1:-${TMPDIR:-/tmp}/vivid-string-catalog}"
resolved="$app/Vivid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ "$build" = 1 ]; then
  # Generating either project and resolving packages rewrites the tracked
  # Package.resolved, so put it back afterwards.
  saved="$(mktemp)"
  cp "$resolved" "$saved"
  trap 'cp "$saved" "$resolved"; rm -f "$saved"' EXIT

  for platform in "project-ios.yml Vivid iOS" "project.yml VividTV tvOS"; do
    read -r spec scheme os <<< "$platform"
    echo "Building $scheme for the $os Simulator"
    (cd "$app" && xcodegen generate --spec "$spec" --quiet)
    xcodebuild build -project "$app/Vivid.xcodeproj" -scheme "$scheme" \
      -destination "generic/platform=$os Simulator" -derivedDataPath "$derived" \
      CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES -quiet
  done
  echo "Vivid.xcodeproj is now the tvOS project. Regenerate it for iOS if needed."
fi

# Only the two app targets: the extensions and packages look strings up in
# their own bundles.
objects="$derived/Build/Intermediates.noindex/Vivid.build"
args=()
while IFS= read -r -d '' file; do
  args+=(--stringsdata "$file")
done < <(find "$objects/Debug-iphonesimulator/Vivid.build" \
  "$objects/Debug-appletvsimulator/VividTV.build" -name '*.stringsdata' -print0)
if [ "${#args[@]}" = 0 ]; then
  echo "No .stringsdata found under $objects" >&2
  exit 1
fi

python3 "$repo/scripts/l10n/string_catalog.py" unmark "$catalog"
xcrun xcstringstool sync "$catalog" "${args[@]}"
python3 "$repo/scripts/l10n/string_catalog.py" mark "$catalog"
echo "Synced $catalog from $((${#args[@]} / 2)) files"
