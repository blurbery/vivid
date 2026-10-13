#!/usr/bin/env bash
# Puts Vivid's patched native audio driver and its LGPL FFmpeg and libmpv
# into an Apple device build, and checks that a finished build really
# contains them.
#
# The Swift package resolves the stock Libmpv from edde746/mpv-build. Vivid's
# audio driver fixes (patches/mpv) are built separately by the
# mpv-audio-driver workflow and have to replace the device slice before
# linking. Without this step a build still compiles and plays, but silently
# ships without the driver fixes, such as AirPlay startup sync.
#
#   install <tvos|ios> <derived-data-path> [--run <workflow-run-id> | --from <artifact folder>]
#       Replaces the resolved device slices of Libmpv and the seven FFmpeg
#       frameworks in <derived-data-path>. Resolve packages into that path
#       first. Without --run or --from, uses the newest successful
#       mpv-audio-driver run built from the same patches/ and workflow as the
#       current checkout. --from takes the folder holding the downloaded
#       artifact's .xcframework.zip files.
#   verify <app, xcarchive or executable>
#       Fails unless the linked binary contains the patched driver, the
#       LGPL FFmpeg and libmpv, and no GPL FFmpeg.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="mpv-audio-driver.yml"
# Strings that exist only in the patched driver. Vivid's Swift code also
# names some driver options and log lines, so those cannot prove the patch
# was linked.
markers=("first start recovery after" "trace edge %s")
# The LGPL engine: FFmpeg's licence string and mpv's recorded build option.
lgpl_markers=("LGPL version 2.1 or later" "-Dgpl=false")
gpl_marker="GPL version 3 or later"
frameworks=(Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale)

work=""
trap '[ -z "$work" ] || rm -rf "$work"' EXIT

fail() { echo "error: $*" >&2; exit 1; }

has_markers() {
  local file="$1" marker
  for marker in "${markers[@]}"; do
    LC_ALL=C grep -aqF -- "$marker" "$file" || return 1
  done
}

has_lgpl_engine() {
  local file="$1" marker
  for marker in "${lgpl_markers[@]}"; do
    LC_ALL=C grep -aqF -- "$marker" "$file" || return 1
  done
  ! LC_ALL=C grep -aqF -- "$gpl_marker" "$file"
}

slice_for() {
  case "$1" in
    tvos) echo "tvos-arm64_arm64e" ;;
    ios) echo "ios-arm64" ;;
    *) fail "platform must be tvos or ios" ;;
  esac
}

# Newest successful driver run whose patches and workflow match this checkout
# and whose artifact for the platform has not expired.
find_run() {
  local platform="$1" patch_tree workflow_blob run sha
  patch_tree="$(git -C "$root" rev-parse HEAD:patches)"
  workflow_blob="$(git -C "$root" rev-parse "HEAD:.github/workflows/$workflow")"
  while read -r run sha; do
    git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q origin "$sha" 2>/dev/null || continue
    [ "$(git -C "$root" rev-parse "$sha:patches" 2>/dev/null)" = "$patch_tree" ] || continue
    [ "$(git -C "$root" rev-parse "$sha:.github/workflows/$workflow" 2>/dev/null)" = "$workflow_blob" ] || continue
    if [ -n "$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" \
        --jq ".artifacts[] | select(.name == \"mpv-$platform-device-audio-driver\" and .expired == false) | .id")" ]; then
      echo "$run"
      return
    fi
  done < <(gh run list --workflow "$workflow" --status success --limit 30 --json databaseId,headSha --jq '.[] | "\(.databaseId) \(.headSha)"')
  fail "no unexpired $workflow artifact matches patches/ and the workflow at HEAD. Run: gh workflow run $workflow -f platform=$platform-device, then try again once it succeeds."
}

install_slice() {
  local platform="$1" derived="$2" source_kind="${3:-}" source_value="${4:-}" slice dir="" run="" name target patched
  slice="$(slice_for "$platform")"
  for name in "${frameworks[@]}"; do
    target="$derived/SourcePackages/artifacts/mpv-build/$name/$name.xcframework/$slice/$name.framework"
    [ -d "$target" ] || fail "$target not found. Resolve packages first: xcodebuild -resolvePackageDependencies -project iosApp/Vivid.xcodeproj -derivedDataPath $derived"
  done

  work="$(mktemp -d)"
  case "$source_kind" in
    --from) dir="$source_value" ;;
    --run|"")
      run="$source_value"
      [ -n "$run" ] || run="$(find_run "$platform")" || exit 1
      gh run download "$run" -n "mpv-$platform-device-audio-driver" -D "$work/download"
      dir="$work/download" ;;
    *) fail "unknown option $source_kind" ;;
  esac
  for name in "${frameworks[@]}"; do
    [ -f "$dir/$name.xcframework.zip" ] || fail "$dir/$name.xcframework.zip not found. The artifact must come from the LGPL engine workflow."
    unzip -q "$dir/$name.xcframework.zip" -d "$work/unzipped"
    [ -f "$work/unzipped/$name.xcframework/$slice/$name.framework/$name" ] || fail "the artifact has no $slice slice of $name"
  done
  patched="$work/unzipped/Libmpv.xcframework/$slice/Libmpv.framework/Libmpv"
  has_markers "$patched" || fail "the artifact's $slice Libmpv does not contain the patched driver"
  LC_ALL=C grep -aqF -- "-Dgpl=false" "$patched" || fail "the artifact's $slice Libmpv is not an LGPL build"

  for name in "${frameworks[@]}"; do
    target="$derived/SourcePackages/artifacts/mpv-build/$name/$name.xcframework/$slice/$name.framework"
    rm -rf "$target"
    cp -R "$work/unzipped/$name.xcframework/$slice/$name.framework" "$target"
  done
  echo "Installed the patched LGPL $slice Libmpv and FFmpeg${run:+ from workflow run $run} into $derived."
  echo "Build or archive with -derivedDataPath $derived, then run: $0 verify <the .xcarchive or .app>"
}

verify_build() {
  local path="${1%/}" app="" exe candidate
  case "$path" in
    *.xcarchive) app="$(find "$path/Products/Applications" -maxdepth 1 -name '*.app' | head -1)" ;;
    *.app) app="$path" ;;
  esac
  if [ -n "$app" ]; then
    exe="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
    # Libmpv is linked into the app executable, or its .debug.dylib in Debug
    # builds. Check the framework too in case a package ships it dynamically.
    for candidate in "$exe" "$exe.debug.dylib" "$app/Frameworks/Libmpv.framework/Libmpv"; do
      [ -f "$candidate" ] && has_markers "$candidate" && has_lgpl_engine "$candidate" && { echo "OK: $app contains the patched audio driver and the LGPL engine."; return; }
    done
  else
    [ -f "$path" ] || fail "$path not found"
    has_markers "$path" && has_lgpl_engine "$path" && { echo "OK: $path contains the patched audio driver and the LGPL engine."; return; }
  fi
  fail "$path does not contain the patched audio driver and the LGPL engine. Install them with: $0 install <tvos|ios> <derived-data-path>, then rebuild."
}

case "${1:-}" in
  install) [ $# -ge 3 ] || fail "usage: $0 install <tvos|ios> <derived-data-path> [--run <id> | --from <artifact folder>]"; install_slice "$2" "$3" "${4:-}" "${5:-}" ;;
  verify) [ $# -eq 2 ] || fail "usage: $0 verify <app, xcarchive or executable>"; verify_build "$2" ;;
  *) fail "usage: $0 install <tvos|ios> <derived-data-path> [--run <id> | --from <artifact folder>] | verify <app, xcarchive or executable>" ;;
esac
