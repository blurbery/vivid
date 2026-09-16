<p align="center">
  <img src="vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Branding</h1>
<p align="center">One mark for light and dark backgrounds.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

The app name is **Vivid**. Keep the public byline in the root README only. Use the GitHub username **blurbery** for the maintainer in documentation, contribution rules and approval requests. The logo remains a symbol without text.

Vivid's symbol uses interlocking ribbons to suggest motion and an abstract V. The mark contains no wordmark or lettering.

## Main logo

The transparent silver mark is Vivid’s main logo. It preserves the metallic lighting and ribbon shape from the owner-approved enhanced artwork. Use it on both light and dark backgrounds, without adding a background box. The root README, documentation headers and website logos use this finish in both light and dark themes.

<table width="100%">
  <thead>
    <tr><th align="left">Appearance</th><th align="left" width="10000">Asset</th><th align="left">Colour</th></tr>
  </thead>
  <tbody>
    <tr><td>Main logo, either theme</td><td><a href="vivid-mark-silver.png">Transparent silver PNG</a></td><td>Silver</td></tr>
    <tr><td>Website favicon</td><td><a href="../../website/public/favicon.png">512 × 512 PNG</a> and <a href="../../website/public/favicon.ico">16–64 px ICO fallback</a></td><td>Enhanced silver icon on black</td></tr>
    <tr><td>Safari favourites</td><td><a href="../../website/public/apple-touch-icon.png">Opaque 512 × 512 PNG</a></td><td>Enhanced silver icon on black</td></tr>
    <tr><td>Animation source artwork</td><td><a href="vivid-mark.png">Transparent PNG</a></td><td>Silver</td></tr>
    <tr><td>Dark-theme compatibility wrapper</td><td><a href="vivid-mark-dark.svg">Transparent SVG wrapper</a></td><td>Silver</td></tr>
  </tbody>
</table>

The transparent PNG is a direct cutout of the approved enhanced icon, preserving its original silver colour pixels and placement on a 1254 × 1254 canvas. Only the background alpha and edge antialiasing are changed. The animation source, website logo and dark-theme SVG wrapper use the same silver artwork. The SVG embeds the PNG; it is not a traced vector master.

The website and Apple TV assembly animations sample the approved silver colours directly. The website reveal does not add a white brightness wash, and the lower logo stays assembled at the bottom of the page. Only the lower Get Vivid section contains a TestFlight link. The website uses tighter section spacing on desktop and mobile, with brighter secondary text and footer links for readability. Static website logos no longer invert or recolour the artwork. The Safari touch icon is resampled from the approved iOS artwork, including its black tile and rim lighting. The existing live favicon artwork is retained separately, including its PNG and ICO fallbacks. The touch icon is opaque, and the ICO retains its 16, 32, 48 and 64 px sizes. Every page links the favicon and Apple touch icon. The website build gives changed icons new content-hashed paths and retains standard root URLs for browser fallback requests. Existing browser caches may take time to refresh.

Preserve the aspect ratio and the clear space already included in the square canvas. Do not add text inside the symbol, stretch it or add shadows. The silver logo does not need a theme switch.

## iOS and Apple TV app icons

Both app targets already include the silver V as their app icon. The source assets below are the ones selected by `ASSETCATALOG_COMPILER_APPICON_NAME` in [the XcodeGen project](../../iosApp/project.yml): `AppIcon` for Vivid on iPhone and iPad, and `TVAppIcon` for VividTV.

<table width="100%">
  <thead><tr><th align="left">iPhone and iPad</th><th align="left" width="10000">Apple TV</th></tr></thead>
  <tbody><tr>
    <td><img src="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160" alt="Vivid iOS app icon: silver V on graphite"></td>
    <td><img src="vivid-tv-app-icon.png" width="267" height="160" alt="Vivid Apple TV app icon: silver V on glossy black with an illuminated rim"></td>
  </tr></tbody>
</table>

The iOS icon is an opaque 1024 × 1024 export from the original 1254 × 1254 artwork. The owner-approved crop removes the extra outer padding while retaining the illuminated rim and ribbon placement. Apple TV uses the same glossy black finish and cool illuminated rim, adapted to its wider icon. Its background fills the tile, and the silver ribbon is enlarged proportionally by 12% from the previous placement. The opaque background and transparent foreground remain separate for parallax. Each size is resampled directly from the original background and transparent ribbon masters with Lanczos filtering, preserving smooth edges. The Apple TV preview combines the 2× layers; Apple supplies the final corner masks, focus and parallax effects.

<table width="100%">
  <thead><tr><th align="left">Use</th><th align="left" width="10000">Source assets</th><th align="left">Pixels</th></tr></thead>
  <tbody>
    <tr><td>iOS and iPadOS app icon</td><td><a href="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png">AppIcon.png</a> · <a href="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/Contents.json">Catalog entry</a></td><td>1024 × 1024</td></tr>
    <tr><td>Apple TV Home screen</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/App%20Icon.imagestack">App Icon layer stack</a></td><td>400 × 240 (1×), 800 × 480 (2×)</td></tr>
    <tr><td>Apple TV App Store</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/App%20Icon%20-%20App%20Store.imagestack">App Store layer stack</a></td><td>1280 × 768</td></tr>
    <tr><td>Apple TV Top Shelf</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/Top%20Shelf%20Image.imageset">Standard images</a> · <a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/Top%20Shelf%20Image%20Wide.imageset">Wide images</a></td><td>1920 × 720 or 2320 × 720, plus 2× versions</td></tr>
  </tbody>
</table>

These source catalogs supply app icons in new builds. Installing a new build is required to see them; updating these assets does not publish an App Store build. Website icons reuse the approved iOS artwork, while documentation marks retain transparent backgrounds.

Apple TV setup and login use `VividMarkSilver`, downsampled to physical display pixels by `VividLogoView`. `VividMarkSource` contains the same enhanced artwork for the star-assembly animation. `VividStartupView` retains its sequence on black, Reduce Motion support and static-mark fallback. Top Shelf uses the enhanced mark on the existing dark background. Home and other root tab pages intentionally omit a separate top-left logo. Physical-device presentation and focus/parallax for this artwork still require verification. The refreshed catalogues passed Apple asset compilation for iOS 18.0 and tvOS 26.0. Image checks confirmed unchanged pixel dimensions, valid file references, opaque app icons and transparent marks. The website asset build passed. Standalone Metal shader compilation was unavailable because the local Xcode Metal toolchain is not installed; startup animation rendering remains unverified.

Provider selection uses the Silo, Emby and Jellyfin logos to identify the supported server types. Vivid keeps its own app icon, startup artwork and branding. Silo and Emby cards open native setup on mobile and Apple TV. Jellyfin remains Coming Soon. App Store submission remains a separate integration step.

## Asset provenance

The owner supplied and approved `vividios.png` as the enhanced icon on 16 September 2026. The transparent version was extracted programmatically from that image with explicit owner approval, preserving original colour pixels. Image-generation cutout attempts were rejected and are not included in these assets. The Apple TV background plate was created with the built-in image-generation tool from the approved iOS reference, following the owner’s request for the same treatment. Its prompt specified a wide, glossy black tile with a cool illuminated rim and no symbol; the existing silver foreground is composited separately.

Use Vivid's name and logo for the app. Server names identify supported connections. Preserve existing code licences, copyright and dependency notices when updating branding.

## Brand policy

Vivid™ and the ribbon logo are trademarks claimed by blurbery. Forks and other projects must use their own name and artwork unless blurbery gives prior, explicit written consent. This includes the silver mark, animated logo and app icons. See [Vivid’s brand and trademark policy](../../TRADEMARK.md).
