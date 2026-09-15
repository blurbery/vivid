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
| Plezy Apple bridge | `8ad17ad38f2ba63576cd7b37b460a4362adb738e` | GPLv3; bundled upstream licence |
| Patched mpv Apple build | `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` | GPLv3 bundles; component licences remain upstream |
| CollectionHStack (tvOS Home rows) | `15baaaa759a0e252addae08431c79a49a25e4afc` | MIT |
| DifferenceKit (collection updates) | 1.3.0, `073b9671ce2b9b5b96398611427a1f929927e428` | MIT |
| FFmpegBuild | `4e58942403d37cceff3a3212e3e026f4205146a2` | LGPL-2.1; embedded FFmpeg and codec dependencies retain the licences recorded below |
| libass | 0.17.1 | ISC |
| FreeType | 2.13.2 | FreeType License |
| FriBidi | 1.0.12 | LGPL-2.1-or-later |
| HarfBuzz | 5.3.1 | MIT |
| ThumbHash decoder | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |

The full version, source and rebuild inventory is maintained in the [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt), alongside the unchanged upstream licence texts. The app exposes these in Settings → About → Open Source Licences.

For the retained iOS engine, FFmpeg remains a set of separate dynamic frameworks. The exact build excludes GPL and nonfree FFmpeg features. VividKit links only the four standalone subtitle/font frameworks from the pinned FFmpegKit source tree; it does not link FFmpegKit's playback code or mpv.

The subtitle/font frameworks are vendored in [VividKit/Vendor](VividKit/Vendor), with their provenance and licence texts. Their simulator and device slices are available as separately replaceable SwiftPM binary targets. External distribution must preserve source and relinking rights for the LGPL components; Vivid's GPL licence and Apple permission do not relicense those dependencies or waive their obligations.

## Timestamp services

Vivid acknowledges [IntroDB](https://introdb.app) and [TheIntroDB](https://theintrodb.org) for community episode timestamps. Selected-file markers take priority. IntroDB is the primary public provider; TheIntroDB fills missing intro, recap or credits markers through public, unauthenticated HTTP lookups. These are external services, not bundled SDKs or databases. Both appear in the separate About → Acknowledgements section on iOS and tvOS; Open Source Licences retains the existing library texts.

TMDB is also credited for metadata and artwork in Acknowledgements. Its logo and attribution appear in Acknowledgements on both platforms, without a duplicate block on About. This product uses the TMDB API but is not endorsed or certified by TMDB.

The separate Acknowledgements page contains service credits, with library licence texts confined to Open Source Licences. Bundled acknowledgement artwork comes from the projects’ official sources:

- IntroDB: `https://introdb.app/favicon.svg`
- TheIntroDB: `https://theintrodb.org/logo-small.svg`
- TMDB: the existing `TMDbAttributionLogo` asset.

The logos identify their respective projects and are not presented as Vivid-owned artwork.


## Lucid Engine dependencies

`iosApp/project.yml` selects `edde746/mpv-build` at
`c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` (mpv 0.41.0 and FFmpeg 8.0.1,
with that repository's Apple patch series). The upstream package declares its
bundled mpv/FFmpeg frameworks GPLv3. Its pinned Package.swift records binary
checksums and the upstream repository contains the corresponding build sources.

`Playback/MPV/MpvPlayerCoreBase.swift` and `MpvPlayerCore.swift` are adapted from
[edde746/plezy](https://github.com/edde746/plezy) at
`8ad17ad38f2ba63576cd7b37b460a4362adb738e`, under its GPLv3 licence, bundled as
`Plezy-GPL-3.0.txt`. Vivid's changes scope compilation to the tvOS experiment,
mount the video in Vivid's existing surface, honour its match-content setting
and disable verbose default logging. Upstream clock, renderer and display-mode
logic is retained. Vivid's Apple distribution permission does not extend to
this third-party code. The new VividMPVPlayer adapter is Vivid-owned code.

This branch is an experiment, not an App Store or TestFlight release. Exact
transitive binary notices and distribution requirements need verification before
any public Apple binary distribution. Existing inventory entries above continue
to describe the retained iOS configuration.
