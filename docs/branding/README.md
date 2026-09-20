<p align="center">
  <img src="vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Branding</h1>
<p align="center">One mark for light and dark backgrounds.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

The app name is **Vivid**. Keep the public byline in the root README only. Use the GitHub username **blurbery** for the maintainer in documentation, contribution rules and approval requests. The logo remains a symbol without text.

Vivid's symbol is a silver V built from two broad pieces with softened angular corners and a diagonal gap. The mark contains no wordmark.

## Main logo

The transparent silver mark is Vivid’s main logo. It uses the owner-approved two-piece shape with straight edges, smoothly joined rounded corners and a restrained silver gradient. Use it on both light and dark backgrounds, without adding a background box. The root README, documentation headers and website logos use this finish in both light and dark themes.

<table width="100%">
  <thead>
    <tr><th align="left">Appearance</th><th align="left" width="10000">Asset</th><th align="left">Colour</th></tr>
  </thead>
  <tbody>
    <tr><td>Main logo, either theme</td><td><a href="vivid-mark-silver.png">Transparent silver PNG</a></td><td>Silver</td></tr>
    <tr><td>Website favicon</td><td><a href="../../website/public/favicon.png">512 × 512 PNG</a> and <a href="../../website/public/favicon.ico">16–64 px ICO fallback</a></td><td>Silver V on charcoal</td></tr>
    <tr><td>Safari favourites</td><td><a href="../../website/public/apple-touch-icon.png">Opaque 512 × 512 PNG</a></td><td>Full-square silver V on charcoal</td></tr>
  </tbody>
</table>

The transparent PNG is exported from [the SVG master](vivid-mark-silver.svg) on the existing 1254 × 1254 canvas. A [transparent PDF master](vivid-mark-silver.pdf) is also available. The SVG uses two smooth paths and continuous gradients, with no embedded bitmap or tessellated shading patches. Documentation headers, website logos and animation sources use PNG exports of the same artwork. Separate light- and dark-theme marks are not needed.

The [iOS app master](vivid-app-icon.svg), [matching small-size master](vivid-app-icon-small.svg), and Apple TV [foreground](vivid-tv-foreground.svg) and [background](vivid-tv-background.svg) are the sources for runtime icons. The rounded [presentation SVG](vivid-presentation.svg) and [presentation PDF](vivid-presentation.pdf) are design previews only. Never place the presentation tile inside an app icon or an in-app logo: that creates an extra inset border and recessed appearance.

The website and Apple TV assembly animations sample the approved silver colours directly. The website, iOS and tvOS reveals do not add a white brightness wash, and the lower logo stays assembled at the bottom of the page. Only the lower Get Vivid section contains a TestFlight link. The website uses tighter section spacing on desktop and mobile, with brighter secondary text and footer links for readability. Static website logos no longer invert or recolour the artwork. The Safari touch icon and website favicons use the approved full-square iOS artwork. The touch icon is opaque, and the ICO retains its 16, 32, 48 and 64 px sizes. Every page links the favicon and Apple touch icon. The website build gives changed icons new content-hashed paths and retains standard root URLs for browser fallback requests. Existing browser caches may take time to refresh.

Preserve the aspect ratio and the clear space already included in the square canvas. Do not add text inside the symbol, stretch it or add shadows. The silver logo does not need a theme switch.

## iOS and Apple TV app icons

Both app targets already include the silver V as their app icon. The source assets below are the ones selected by `ASSETCATALOG_COMPILER_APPICON_NAME` in [the XcodeGen project](../../iosApp/project.yml): `AppIcon` for Vivid on iPhone and iPad, and `TVAppIcon` for VividTV.

<table width="100%">
  <thead><tr><th align="left">iPhone and iPad</th><th align="left" width="10000">Apple TV</th></tr></thead>
  <tbody><tr>
    <td><img src="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160" alt="Vivid iOS app icon: silver V on graphite"></td>
    <td><img src="vivid-tv-app-icon.png" width="267" height="160" alt="Vivid Apple TV app icon: silver V on a full-width dark background"></td>
  </tr></tbody>
</table>

The iOS icon uses opaque, full-square PNGs exported from the vector at the catalogue sizes, including 1024 × 1024. Its background reaches every edge. There is no nested rounded tile, decorative outer rim or extra padding; iOS applies the outer corner mask. The mark placement and diagonal gap match the approved app-size preview. The background fades vertically from charcoal (`#252525`) through `#191919` to near-black (`#101010`), without a baked-in border.

Apple TV uses the approved landscape composition with a full-width dark background and a separate transparent silver foreground. The existing layer order remains foreground first. Both layers fill their canvases; clear space around the foreground mark allows parallax without adding an inset background panel. Exports are generated directly from the vector, with supersampling for smaller sizes. Apple supplies the final corner masks, focus and parallax effects.

<table width="100%">
  <thead><tr><th align="left">Use</th><th align="left" width="10000">Source assets</th><th align="left">Pixels</th></tr></thead>
  <tbody>
    <tr><td>iOS and iPadOS app icon</td><td><a href="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png">AppIcon.png</a> · <a href="../../iosApp/iosApp/Assets.xcassets/AppIcon.appiconset/Contents.json">Catalog entry</a></td><td>20–180 px catalogue exports and 1024 × 1024 marketing icon</td></tr>
    <tr><td>Apple TV Home screen</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/App%20Icon.imagestack">App Icon layer stack</a></td><td>400 × 240 (1×), 800 × 480 (2×)</td></tr>
    <tr><td>Apple TV App Store</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/App%20Icon%20-%20App%20Store.imagestack">App Store layer stack</a></td><td>1280 × 768</td></tr>
    <tr><td>Apple TV Top Shelf</td><td><a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/Top%20Shelf%20Image.imageset">Standard images</a> · <a href="../../iosApp/iosApp/Assets.xcassets/TVAppIcon.brandassets/Top%20Shelf%20Image%20Wide.imageset">Wide images</a></td><td>1920 × 720 or 2320 × 720, plus 2× versions</td></tr>
  </tbody>
</table>

The tvOS foreground uses the approved landscape placement over the same charcoal-to-near-black treatment. Both Home Screen resolutions and the App Store layer use the same vector placement. Top Shelf exports centre the same proportional mark on their wider canvases.

These source catalogs supply app icons in new builds. Installing a new build is required to see them; updating these assets does not publish an App Store build. Website icons reuse the approved iOS artwork, while documentation marks retain transparent backgrounds.

iOS and Apple TV setup and login use `VividMarkSilver`, downsampled to physical display pixels by `VividLogoView`. `VividMarkSource` contains the same refined artwork for the star-assembly animation. `VividStartupView` retains its sequence on black, Reduce Motion support and static-mark fallback. Cold launch keeps the completed star frame visible while the destination fades in over 0.55 seconds, with a subtle reduction in logo size. Reduce Motion uses a 0.2-second fade without scaling. Profile interaction and accessibility remain gated until the handoff completes. The static fallback uses the same available canvas size as the animated logo. Top Shelf uses the same two-piece mark and charcoal background. Home and other root tab pages intentionally omit a separate top-left logo. Physical-device presentation and focus/parallax for this artwork still require verification. The updated catalogue passed `actool` compilation for iOS 18.0 and tvOS 26.0. Sandbox warnings prevented Simulator service access, so these checks do not establish simulator or device appearance. Image checks cover file references, expected dimensions, opaque app icons, transparent marks and full-width backgrounds without an inset tile. The website asset build passed. Startup animation rendering and physical-device appearance remain unverified.

Provider selection uses the Silo, Emby and Jellyfin logos to identify the supported server types. Vivid keeps its own app icon, startup artwork and branding. Silo and Emby cards open native setup on mobile and Apple TV. Jellyfin remains Coming Soon. App Store submission remains a separate integration step.

## Asset provenance

On 20 September 2026, blurbery selected and approved the two-piece silver V, including its proportions, spacing and charcoal background, and requested replacing the old logos throughout the repository. The concept was developed with AI image generation, then reconstructed as vector paths and refined to remove traced edge irregularities. Full-square runtime icons preserve the approved placement; rounded presentation tiles are previews only. The SVG masters are the source for raster exports at each required size, with supersampling for smaller images. On-device icon rendering, startup animation and tvOS focus/parallax still need verification.

Use Vivid's name and logo for the app. Server names identify supported connections. Preserve existing code licences, copyright and dependency notices when updating branding.

## Brand policy

Vivid™ and the two-piece V logo are trademarks claimed by blurbery. Forks and other projects must use their own name and artwork unless blurbery gives prior, explicit written consent. This includes the silver mark, animated logo and app icons. See [Vivid’s brand and trademark policy](../../TRADEMARK.md).
