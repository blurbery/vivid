<p align="center">
  <img src="docs/branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Third-Party Libraries</h1>
<p align="center">Playback, artwork and media dependencies.</p>
<p align="center"><a href="README.md">Home</a> · <a href="docs/README.md">Documentation</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid and VividKit as a whole use GPL-3.0-only with the [Apple distribution permission](LICENSE-APPLE-EXCEPTION). The [Vivid attribution terms](ATTRIBUTION.md) apply only to the covered material identified there. Third-party libraries retain their own licences.

| Component | Version / revision | Licence |
| --- | --- | --- |
| AetherEngine (tvOS playback) | 6.80.0, local integration changes | LGPL-3.0 with Apple Store / DRM Exception; see `AetherEngine/LICENSE` |
| LibDovi (tvOS playback) | 2.1.0 | MIT |
| FFmpegBuild | `421e13be7061de67d91b85ac34a6b22a002b164f` | LGPL-2.1; embedded FFmpeg and codec dependencies retain the licences recorded below |
| libass | 0.17.1 | ISC |
| FreeType | 2.13.2 | FreeType License |
| FriBidi | 1.0.12 | LGPL-2.1-or-later |
| HarfBuzz | 5.3.1 | MIT |
| ThumbHash decoder | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |

The full version, source and rebuild inventory is maintained in the [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt), alongside the unchanged upstream licence texts. The app exposes these in Settings → About → Open Source Licences.

FFmpeg remains a set of separate dynamic frameworks. Its binary packaging retains the `AetherLib` prefix, which identifies the packaged FFmpeg frameworks. The exact build excludes GPL and nonfree FFmpeg features. VividKit links only the four standalone subtitle/font frameworks from the pinned FFmpegKit source tree; it does not link FFmpegKit's playback code or mpv.

The subtitle/font frameworks are vendored in [VividKit/Vendor](VividKit/Vendor), with their provenance and licence texts. Their simulator and device slices are available as separately replaceable SwiftPM binary targets. External distribution must preserve source and relinking rights for the LGPL components; Vivid's GPL licence and Apple permission do not relicense those dependencies or waive their obligations.

## Timestamp services

Vivid acknowledges [IntroDB](https://introdb.app) and [TheIntroDB](https://theintrodb.org) for community episode timestamps. Selected-file markers take priority. IntroDB is the primary public provider; TheIntroDB fills missing intro, recap or credits markers through public, unauthenticated HTTP lookups. These are external services, not bundled SDKs or databases. Both appear in the separate About → Acknowledgements section on iOS and tvOS; Open Source Licences retains the existing library texts.

TMDB is also credited for metadata and artwork in Acknowledgements. Its logo and attribution appear in Acknowledgements on both platforms, without a duplicate block on About. This product uses the TMDB API but is not endorsed or certified by TMDB.

The separate Acknowledgements page also thanks AetherEngine. It contains logo cards and short credits, with licence texts confined to Open Source Licences. Bundled acknowledgement artwork comes from the projects’ official sources:

- AetherEngine: `https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/.github/aetherengine-logo.png`
- IntroDB: `https://introdb.app/favicon.svg`
- TheIntroDB: `https://theintrodb.org/logo-small.svg`
- TMDB: the existing `TMDbAttributionLogo` asset.

The logos identify their respective projects and are not presented as Vivid-owned artwork.
