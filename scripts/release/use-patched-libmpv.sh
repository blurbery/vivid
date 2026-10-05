#!/usr/bin/env bash
# Puts Vivid's patched native audio driver into an Apple device build, and
# checks that a finished build really contains it.
#
# The Swift package resolves the stock Libmpv from edde746/mpv-build. Vivid's
# audio driver fixes (patches/mpv) are built separately by the
# mpv-audio-driver workflow and have to replace the device slice before
# linking. Without this step a build still compiles and plays, but silently
# ships without the driver fixes, such as AirPlay startup sync.
#
#   install <tvos|ios> <derived-data-path> [--run <workflow-run-id> | --from <Libmpv.xcframework.zip>]
#       Replaces the resolved device slice in <derived-data-path>. Resolve
#       packages into that path first. Without --run or --from, uses the
#       newest successful mpv-audio-driver run built from the same
#       patches/mpv as the current checkout.
#   verify <app, xcarchive or executable>
#       Fails unless the linked binary contains the patched driver.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="mpv-audio-driver.yml"
# Strings that exist only in the patched driver. Vivid's Swift code also
# names some driver options and log lines, so those cannot prove the patch
# was linked.
markers=("first start recovery after" "trace edge %s")

work=""
trap '[ -z "$work" ] || rm -rf "$work"' EXIT

fail() { echo "error: $*" >&2; exit 1; }

has_markers() {
  local file="$1" marker
  for marker in "${markers[@]}"; do
    LC_ALL=C grep -aqF -- "$marker" "$file" || return 1
  done
}

slice_for() {
  case "$1" in
    tvos) echo "tvos-arm64_arm64e" ;;
    ios) echo "ios-arm64" ;;
    *) fail "platform must be tvos or ios" ;;
  esac
}

# Newest successful driver run whose patch matches this checkout and whose
# artifact for the platform has not expired.
find_run() {
  local platform="$1" patch_tree run sha
  patch_tree="$(git -C "$root" rev-parse HEAD:patches/mpv)"
  while read -r run sha; do
    git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q origin "$sha" 2>/dev/null || continue
    [ "$(git -C "$root" rev-parse "$sha:patches/mpv" 2>/dev/null)" = "$patch_tree" ] || continue
    if [ -n "$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" \
        --jq ".artifacts[] | select(.name == \"mpv-$platform-device-audio-driver\" and .expired == false) | .id")" ]; then
      echo "$run"
      return
    fi
  done < <(gh run list --workflow "$workflow" --status success --limit 30 --json databaseId,headSha --jq '.[] | "\(.databaseId) \(.headSha)"')
  fail "no unexpired $workflow artifact matches patches/mpv at HEAD. Run: gh workflow run $workflow -f platform=$platform-device, then try again once it succeeds."
}

install_slice() {
  local platform="$1" derived="$2" source_kind="${3:-}" source_value="${4:-}" slice target zip run=""
  slice="$(slice_for "$platform")"
  target="$derived/SourcePackages/artifacts/mpv-build/Libmpv/Libmpv.xcframework/$slice/Libmpv.framework"
  [ -d "$target" ] || fail "$target not found. Resolve packages first: xcodebuild -resolvePackageDependencies -project iosApp/Vivid.xcodeproj -derivedDataPath $derived"

  work="$(mktemp -d)"
  case "$source_kind" in
    --from) zip="$source_value" ;;
    --run|"")
      run="$source_value"
      [ -n "$run" ] || run="$(find_run "$platform")" || exit 1
      gh run download "$run" -n "mpv-$platform-device-audio-driver" -D "$work/download"
      zip="$work/download/Libmpv.xcframework.zip" ;;
    *) fail "unknown option $source_kind" ;;
  esac
  [ -f "$zip" ] || fail "$zip not found"
  unzip -q "$zip" -d "$work/unzipped"
  local patched="$work/unzipped/Libmpv.xcframework/$slice/Libmpv.framework"
  [ -f "$patched/Libmpv" ] || fail "the artifact has no $slice slice"
  has_markers "$patched/Libmpv" || fail "the artifact's $slice slice does not contain the patched driver"

  rm -rf "$target"
  cp -R "$patched" "$target"
  echo "Installed the patched $slice Libmpv${run:+ from workflow run $run} into $derived."
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
      [ -f "$candidate" ] && has_markers "$candidate" && { echo "OK: $app contains the patched audio driver."; return; }
    done
  else
    [ -f "$path" ] || fail "$path not found"
    has_markers "$path" && { echo "OK: $path contains the patched audio driver."; return; }
  fi
  fail "$path does not contain the patched audio driver. Install it with: $0 install <tvos|ios> <derived-data-path>, then rebuild."
}

case "${1:-}" in
  install) [ $# -ge 3 ] || fail "usage: $0 install <tvos|ios> <derived-data-path> [--run <id> | --from <zip>]"; install_slice "$2" "$3" "${4:-}" "${5:-}" ;;
  verify) [ $# -eq 2 ] || fail "usage: $0 verify <app, xcarchive or executable>"; verify_build "$2" ;;
  *) fail "usage: $0 install <tvos|ios> <derived-data-path> [--run <id> | --from <zip>] | verify <app, xcarchive or executable>" ;;
esac
