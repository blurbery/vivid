<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Localisation</h1>
<p align="center">How Vivid picks its language and how its strings are kept.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid is written in English and follows the device's language. English is the source language and the fallback: any language Vivid has no translation for shows English. There is no language picker inside the app.

Vivid only ships English today. The String Catalog holds the English base so translations can be added without more setup.

## How the language is chosen

<table width="100%">
  <thead>
    <tr><th align="left">Device</th><th align="left" width="10000">Behaviour</th></tr>
  </thead>
  <tbody>
    <tr><td>iPhone and iPad</td><td>Vivid uses the first language in Settings > General > Language & Region that it has a translation for. Once Vivid ships a second language, iOS adds Settings > Vivid > Language so people can choose a different language for Vivid alone. That option only appears when the device lists more than one preferred language.</td></tr>
    <tr><td>Apple TV</td><td>tvOS has no per-app language setting. Vivid uses the first supported language in Settings > General > Language.</td></tr>
  </tbody>
</table>

Titles, overviews, genres and other metadata come from Silo, Emby or Jellyfin in the server's metadata language. Vivid's language doesn't change them.

The English text mixes Australian and US spelling today, for example "Customise Tab Bar" and "Add to Favorites". Every English locale sees the same text unless a separate English variant is added.

## The String Catalog

`iosApp/Resources/Localizable.xcstrings` is shared by the iOS app (`Vivid`) and the tvOS app (`VividTV`). It holds every string the Swift compiler can look up for either app: literals passed to `Text`, `Button`, `Toggle`, `Label`, `Picker`, `navigationTitle` and other APIs that take a `LocalizedStringKey`, plus `String(localized:)` and `LocalizedStringResource` literals. Interpolated strings become format keys, such as `%lld` for an integer.

Every entry is marked manual, and [the sync script](../scripts/l10n/sync-string-catalog.sh) maintains the catalog rather than Xcode. The two apps are generated from separate XcodeGen specs, and Xcode syncs a catalog with only the platform it just built. Left to itself, an iOS build would delete every untranslated string that only Apple TV uses, and a tvOS build would do the reverse. Xcode never changes manual entries, and compiler extraction (`SWIFT_EMIT_LOC_STRINGS`) is off in `iosApp/project-common.yml`, so everyday builds leave the catalog alone.

### Updating it

Run the script after adding or changing interface text, and always before sending strings for translation:

```bash
scripts/l10n/sync-string-catalog.sh
```

It builds both apps for the simulator with compiler extraction on, syncs both sets of strings in one pass and marks every entry manual again. New strings are added. Strings the code no longer uses are removed, or marked stale if they have translations. It restores `Package.resolved` when it finishes and leaves `Vivid.xcodeproj` as the tvOS project.

The first run builds both apps from scratch. Later runs reuse the derived data in `$TMPDIR/vivid-string-catalog` and build incrementally. Pass a fresh derived data path to drop strings from Swift files that were deleted, or `--no-build` to sync again from the last builds.

A key added to the catalog by hand is removed on the next sync unless it has a translation, so write every interface string as a literal in Swift.

## Adding a language

1. Open the catalog in Xcode and add the language. Translate in the catalog editor, or export with `xcodebuild -exportLocalizations` and import the translated `.xcloc`.
2. Run the sync script so the catalog matches both apps.
3. Finish the items under [Not localised yet](#not-localised-yet) that the language needs.
4. Check iPhone, iPad and Apple TV in that language, including long strings in buttons, tab bars and Apple TV menus.

Right-to-left languages such as Arabic and Hebrew mirror the layout. Treat adding one as a design change and get blurbery's approval first.

## Not localised yet

These parts show English even after a translation is added.

<table width="100%">
  <thead>
    <tr><th align="left">Area</th><th align="left" width="10000">What needs to change</th></tr>
  </thead>
  <tbody>
    <tr><td>Text built from variables</td><td><code>Text(someString)</code> and similar calls show a <code>String</code> as it is, and many settings options get their labels from <code>title: String</code> properties, such as <code>VividAppTheme.title</code>. Text written by Vivid needs to become a <code>LocalizedStringResource</code> or come from <code>String(localized:)</code>. Server data such as titles stays a plain <code>String</code>.</td></tr>
    <tr><td>Language names</td><td><code>PlayerTrack.languageDisplayName</code>, <code>OverlayRegistry.formatLanguageName</code> and <code>SubtitleDisplayOrder.languageDisplayName</code> use English names on purpose: detail rows and subtitle grouping share one English name table, and overlay badges match the web app. Change them together, keeping the grouping keys separate from the displayed names.</td></tr>
    <tr><td>Dates</td><td>Formatters that read server dates use <code>en_US_POSIX</code> and must stay that way. Any formatter that shows a date with a fixed format should use <code>.formatted()</code> or a template instead.</td></tr>
    <tr><td>Local network prompt</td><td><code>NSLocalNetworkUsageDescription</code> needs an <code>InfoPlist.xcstrings</code> holding only that key. Leave <code>CFBundleDisplayName</code> out, because a localised name would replace the tvOS <code>$(VIVID_TV_DISPLAY_NAME)</code> build setting.</td></tr>
    <tr><td>Extensions</td><td>Top Shelf (<code>iosApp/TopShelf</code>) and the downloads Live Activity (<code>iosApp/DownloadsActivity</code>) look strings up in their own bundles, so each needs its own catalog.</td></tr>
  </tbody>
</table>
