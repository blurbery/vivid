<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Localisation</h1>
<p align="center">How Vivid picks its language and how its strings are kept.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid is available in English, French, German, Spanish, Japanese and Simplified Chinese. It follows the device's language, and Settings > General > Language overrides that on iPhone, iPad and Apple TV. English is the source language and the fallback: anything without a translation shows English.

> [!NOTE]
> The French, German, Spanish, Japanese and Simplified Chinese translations were made with AI assistance and haven't been reviewed by native speakers yet. Corrections are welcome.

## How the language is chosen

<table width="100%">
  <thead>
    <tr><th align="left">Setting</th><th align="left" width="10000">Behaviour</th></tr>
  </thead>
  <tbody>
    <tr><td>Device language</td><td>By default Vivid uses the first language in the device's list that it has, or English.</td></tr>
    <tr><td>Settings > General > Language</td><td>System, or one of the six languages, each named in its own language. The choice is saved as Vivid's own <code>AppleLanguages</code>, the same value iOS's per-app Language setting uses, and takes effect after Vivid is closed in the app switcher and opened again.</td></tr>
    <tr><td>iPhone and iPad</td><td>Settings > Vivid > Language changes the same value. iOS shows it when the device lists more than one language.</td></tr>
    <tr><td>Apple TV</td><td>tvOS has no per-app language setting, so Vivid's own setting is the way to choose.</td></tr>
    <tr><td>Top Shelf</td><td>Follows Vivid's choice the next time it loads. Vivid saves the choice under <code>vivid.appLanguage.v1</code> in the App Group and asks tvOS to reload Top Shelf. The extension looks its rows up in that language on every load and copies the choice into its own <code>AppleLanguages</code> for anything else it shows.</td></tr>
    <tr><td>Downloads Live Activity</td><td>Its labels follow the device's language. The titles Vivid sends it use Vivid's language.</td></tr>
  </tbody>
</table>

Dates, numbers, durations and language names follow Vivid's language with the device's region.

## Metadata

Library metadata (titles, overviews, taglines, genres and episode names) comes from Silo, Emby or Jellyfin in the server's metadata language, and Vivid's language doesn't change it. Silo sets this per profile (`catalog.metadata_language`, "Library default" when unset), and Emby and Jellyfin set it per library on the server. These settings are shared by every device using that profile or library, so Vivid doesn't change them to match a device's language. Silo also names its own Home rows, such as Continue Watching and its trending rows, so they appear as the server writes them. Vivid writes Emby and Jellyfin's Home row titles itself, so those follow Vivid's language.

What Vivid looks up on TMDb itself follows Vivid's language: collection names and the Calendar's Trending titles and overviews. `VividAppLanguage.tmdbLanguage` gives TMDb's code (`fr-FR`, `de-DE`, `es-ES`, `ja-JP`, `zh-CN`, or none for English), the TMDb caches are keyed by it, and an overview TMDb hasn't translated falls back to English. Studios & Networks stays in English because it matches TMDb titles against the library. [The TMDb relay](tmdb-relay.md) accepts `language` only on the routes that use it; deploy the relay before an app build that sends it.

## The String Catalogs

<table width="100%">
  <thead>
    <tr><th align="left">Catalog</th><th align="left" width="10000">Holds</th></tr>
  </thead>
  <tbody>
    <tr><td><code>iosApp/Resources/Localizable.xcstrings</code></td><td>Everything the iOS app (<code>Vivid</code>) and the tvOS app (<code>VividTV</code>) show</td></tr>
    <tr><td><code>iosApp/TopShelf/Localizable.xcstrings</code></td><td>Top Shelf's rows, including the shared code it compiles</td></tr>
    <tr><td><code>iosApp/DownloadsActivity/Localizable.xcstrings</code></td><td>The downloads Live Activity</td></tr>
    <tr><td><code>iosApp/Resources/InfoPlist.xcstrings</code></td><td>Only <code>NSLocalNetworkUsageDescription</code>, the local network prompt. <code>CFBundleDisplayName</code> stays out because a localised name would replace the tvOS <code>$(VIVID_TV_DISPLAY_NAME)</code> build setting.</td></tr>
  </tbody>
</table>

The Localizable catalogs hold every string the Swift compiler can look up: literals passed to `Text`, `Button`, `Toggle`, `Label`, `Picker`, `navigationTitle` and other APIs that take a `LocalizedStringKey`, plus `String(localized:)` and `LocalizedStringResource` literals. Interpolated strings become format keys, such as `%lld` for an integer, and counts use the catalog's plural variations.

Every entry is marked manual, and [the sync script](../scripts/l10n/sync-string-catalog.sh) maintains the catalogs rather than Xcode. The two apps are generated from separate XcodeGen specs, and Xcode syncs a catalog with only the platform it just built. Left to itself, an iOS build would delete every untranslated string that only Apple TV uses, and a tvOS build would do the reverse. Xcode never changes manual entries, and compiler extraction (`SWIFT_EMIT_LOC_STRINGS`) is off in `iosApp/project-common.yml`, so everyday builds leave the catalogs alone.

### Updating them

Run the script after adding or changing interface text, and always before sending strings for translation:

```bash
scripts/l10n/sync-string-catalog.sh
```

It builds both apps for the simulator with compiler extraction on, syncs each catalog from its own targets in one pass and marks every entry manual again. New strings are added. Strings the code no longer uses are removed, or marked stale if they have translations. Plural variations and translations are kept. It restores `Package.resolved` when it finishes and leaves `Vivid.xcodeproj` as the tvOS project.

The first run builds both apps from scratch. Later runs reuse the derived data in `$TMPDIR/vivid-string-catalog` and build incrementally. Pass a fresh derived data path to drop strings from Swift files that were deleted, or `--no-build` to sync again from the last builds.

A key added to a catalog by hand is removed on the next sync unless it has a translation, so write every interface string in Swift.

## Writing translatable code

- **SwiftUI literals** passed to `Text`, `Button`, `Label` and similar are translatable already.
- **Text held in a `String`** needs `String(localized:)` where it's written. Keep identifiers, saved values, comparisons and anything sent to a server on a stable English or raw value, and add a display property for what people see, as `AppTab.title`, `AppHealthReport.displaySummary`, `SubtitleDisplayOrder.displayLanguageName(_:)` and `activeRouteDisplayLabel` do.
- **Shared components** that take visible text mirror `Text`: an initialiser taking `LocalizedStringKey` (or `LocalizedStringResource`) for literals, and a generic `StringProtocol` initialiser marked `@_disfavoredOverload` that shows a variable as it is. Without `@_disfavoredOverload`, or with a concrete `String` overload, literals pick the verbatim initialiser and stop being translated.
- **Server text** is never passed to `LocalizedStringKey(...)`, where a `%` in a title would be read as a format specifier.
- **Counts** are one interpolated string, `"\(count) items"`, with `one` and `other` variations in the catalog. Don't add an English `s` by hand.
- **Sentences** are written whole, `"\(count) of \(total)"`, never joined from pieces, and any word inserted into one is translated too.
- **Optional parameters:** a ternary of literals passed to an Optional `LocalizedStringResource?` only has its first branch extracted. Give each branch its own `Text` or `String(localized:)`.
- **One English word with two meanings** gets its own key, such as `String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")` beside the Series tab.
- **Playback failure messages** stay English where they're made, because their wording drives route fallback, diagnostics and reports to the server. `PlaybackFailureText` translates them where they're shown.
- **Not translated:** logs, diagnostics reports sent to Vivid, identifiers, product names, and legal text (the copyright line, the TMDB attribution, licences and the privacy policy).

## Adding a language

1. Add a case to `VividAppLanguage` with its native name and TMDb code.
2. Translate the four catalogs in Xcode's catalog editor, or export with `xcodebuild -exportLocalizations` and import the translated `.xcloc`. Plural keys need the language's plural forms.
3. Run the sync script so the catalogs match both apps.
4. Check iPhone, iPad and Apple TV in that language, including long strings in buttons, tab bars and Apple TV menus.

Right-to-left languages such as Arabic and Hebrew mirror the layout. Treat adding one as a design change and get blurbery's approval first.

## Tests

Unit tests that check visible text expect English, which is what the simulators used by CI run in.
