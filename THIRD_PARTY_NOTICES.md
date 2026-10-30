<p align="center">
  <img src="docs/branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Third-Party Libraries</h1>
<p align="center">Playback, artwork and media dependencies.</p>
<p align="center"><a href="README.md">Home</a> · <a href="docs/README.md">Documentation</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses GPL-3.0-only with the [Apple distribution permission](LICENSE-APPLE-EXCEPTION). The [Vivid attribution terms](ATTRIBUTION.md) apply only to the covered material identified there. Third-party libraries retain their own licences.

| Component | Version / revision | Licence |
| --- | --- | --- |
| Lucid media engine package (`blurbery/lucid-engine`, product `LucidEngine`, release `0.1.0`) | `53ebeac793f251df987a8d80b997e7fe8064d1b7` | mpv and FFmpeg LGPL-2.1-or-later as built; every library's licence in the package's [NOTICE](https://github.com/blurbery/lucid-engine/blob/53ebeac793f251df987a8d80b997e7fe8064d1b7/NOTICE) |
| CollectionHStack (tvOS Home rows) | `15baaaa759a0e252addae08431c79a49a25e4afc` | MIT |
| DifferenceKit (CollectionHStack dependency) | 1.3.0, `073b9671ce2b9b5b96398611427a1f929927e428` | Apache-2.0 |
| ThumbHash decoder (adapted) | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |
| tvOS media catalog sample code (adapted, Apple) | 2024 sample | Apple sample code licence (MIT-style) |

This file is the full inventory of third-party components in both apps. The [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt) and the upstream licence text of every component, each with a header giving its version and source, are shown in Settings → About → Open Source Licences and at [vividapp.co/licences](https://vividapp.co/licences); keep both matched to this list. [`licences.json`](iosApp/Resources/OpenSourceLicenses/licences.json) is the list both use. A licence body that Vivid or several components use word for word (Apache 2.0, GPL 3.0 and LGPL 2.1) is stored once, and each component that uses it keeps its own notice with a marker line where the text was; `scripts/tests/licence-texts-tests.py` proves every original file still rebuilds byte for byte, and PR checks run it on every pull request.

## Timestamp services

Vivid acknowledges [IntroDB](https://introdb.app) and [TheIntroDB](https://theintrodb.org) for community episode timestamps. Selected-file markers take priority. TheIntroDB is the primary public provider; IntroDB fills missing intro, recap or credits markers. Both are public, unauthenticated HTTP lookups. These are external services, not bundled SDKs or databases. Both appear in the separate About → Acknowledgements section on iOS and tvOS; Open Source Licences retains the existing library texts.

TMDB is also credited for metadata and artwork in Acknowledgements. Its logo and attribution appear in Acknowledgements on both platforms, without a duplicate block on About. This product uses the TMDB API but is not endorsed or certified by TMDB.

The separate Acknowledgements page contains service credits, with library licence texts confined to Open Source Licences. Bundled acknowledgement artwork comes from the projects’ official sources:

- IntroDB: `https://introdb.app/favicon.svg`
- TheIntroDB: `https://theintrodb.org/logo-small.svg`
- TMDB: the existing `TMDbAttributionLogo` asset, and the Primary Short logo from `https://www.themoviedb.org/about/logos-attribution` as the `TMDbRatingMark` asset shown beside TMDB ratings on detail pages.

The logos identify their respective projects and are not presented as Vivid-owned artwork.

## Air times

The Calendar uses [TVmaze](https://www.tvmaze.com)'s public API for episode air times, through Vivid's relay. TVmaze's data is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), which asks for credit with a link back. TVmaze is credited in Acknowledgements on both platforms, with a symbol rather than its logo, and under the Calendar's Upcoming list. Vivid shows the air times and doesn't redistribute TVmaze's data. It is an external service, not a bundled SDK or database.

## Server and service names

Silo, Emby, Jellyfin, MDBList, Simkl, OpenSubtitles, TMDB and TVmaze are trademarks of their respective owners. Vivid shows the Silo, Emby and Jellyfin names and logos to identify the servers it connects to (including on the MDBList plugin page, which shows that MDBList works with Emby and Jellyfin), and the MDBList, Simkl, OpenSubtitles, TMDB and TVmaze names (and the TMDB logo, as its attribution requires) to identify the services it connects to. Studios & Networks shows studio and network logos supplied by TMDb at runtime; none are bundled with the app. All of these names and logos belong to their owners, and Vivid is an independent app that is not endorsed by any of them. The Jellyfin project publishes its logo artwork under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The Silo wordmark appears only on the server picker to identify the Silo choice, a referential “works with Silo” use that [Silo’s trademark policy](https://github.com/Silo-Server/siloserver.org/blob/main/TRADEMARK.md#uses-that-are-always-fine--no-permission-needed) allows without permission; its brand-asset notice is in `iosApp/iosApp/Assets.xcassets/NOTICE`.

## Lucid Engine dependencies (iOS and tvOS)

`iosApp/project-ios.yml` and `iosApp/project.yml` pin [`blurbery/lucid-engine`](https://github.com/blurbery/lucid-engine) at
`53ebeac793f251df987a8d80b997e7fe8064d1b7` (release [`0.1.0`](https://github.com/blurbery/lucid-engine/releases/tag/v0.1.0), tag `v0.1.0`) and link its
`LucidEngine` product. Its [`NOTICE`](https://github.com/blurbery/lucid-engine/blob/53ebeac793f251df987a8d80b997e7fe8064d1b7/NOTICE)
and `LICENSES` folder list every library it contains, with version, upstream
commit and licence text, its README describes the release, and its
`Package.swift` records the URL and SHA-256 checksum of every binary. The
package supplies static libraries, which are linked into the app executable.

Vivid's own engine pipeline built every library in this release from its
pinned upstream source, applying Vivid's patch series where a library has
one. The one part not compiled from source is the Rust 1.98.0 standard
library linked into libdovi, which comes from the Rust project's prebuilt
`rust-std` archive for each target, pinned by URL and SHA-256 in
`engine/pins.ini`. The corresponding source is this repository's
[`engine/`](engine) at
[`fcb6782121e72c6ed755336be913c036f4679ddb`](https://github.com/blurbery/vivid/tree/fcb6782121e72c6ed755336be913c036f4679ddb/engine),
the commit the release was built from: the pipeline (`engine/lucid.py`), the
upstream sources pinned by URL, commit and SHA-256 (`engine/pins.ini`), the
build configuration and every patch (`engine/patches`). The
[Lucid Engine build guide](docs/cores/lucid-engine-build.md) explains how to
run it. mpv is built with `-Dgpl=false` and FFmpeg without `--enable-gpl` or
`--enable-version3`, so both are LGPL-2.1-or-later as built. FFmpeg uses
Apple's Secure Transport for HTTPS, so there is no OpenSSL.

Each patch is licensed like the library it patches:

| Library | Patches | Licence of the patches |
| --- | --- | --- |
| mpv | Vivid's `0002`, `0010` to `0016`, `0020` to `0025` and `0040`; `0001` is an unchanged upstream mpv commit | LGPL-2.1-or-later |
| FFmpeg | Vivid's `0001`, `0002` and `0010` to `0012` | LGPL-2.1-or-later |
| libass | `0001`, upstream libass commit `057a5334`, and `0002`, upstream libass pull request #951, both unchanged; Vivid's `0010` | ISC |
| libdovi | Vivid's `0001` | MIT |
| libbluray | Vivid's `0001` | LGPL-2.1-or-later |
| uavs3d | Vivid's `0001` | BSD-3-Clause |

| Library | Version | Licence |
| --- | --- | --- |
| mpv (libmpv) | 0.41.0 | LGPL-2.1-or-later as built (`-Dgpl=false`) |
| FFmpeg (libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale) | 8.0.1 | LGPL-2.1-or-later as built |
| libass | 0.17.5 | ISC |
| dav1d | 1.5.3 | BSD-2-Clause |
| libdovi (`dolby_vision` crate, its 12 Rust crate dependencies and the Rust 1.98.0 standard library) | 3.3.2 | MIT; crates MIT, Apache-2.0 or zlib (MIT used); Rust standard library MIT or Apache-2.0 |
| FreeType | 2.12.1 | FreeType Licence |
| FriBidi | 1.0.12 | LGPL-2.1-or-later |
| HarfBuzz | 8.1.1 | MIT |
| libunibreak | 6.1 | zlib |
| libplacebo, including fast_float, the glad OpenGL loader and Vulkan-Headers | 7.351.0 | LGPL-2.1-or-later; fast_float MIT; glad CC0-1.0 and Apache-2.0; Vulkan-Headers MIT |
| Little CMS | 2.17 | MIT |
| MoltenVK, including SPIRV-Cross, SPIRV-Tools, SPIRV-Headers, Vulkan-Headers and cereal | 1.4.1 | Apache-2.0; SPIRV-Headers and Vulkan-Headers MIT; cereal BSD-3-Clause |
| shaderc, including glslang and SPIRV-Tools | 2025.5 | Apache-2.0; glslang BSD-3-Clause, BSD-2-Clause, MIT and Apache-2.0 |
| uavs3d | 1.2 | BSD-3-Clause |
| libbluray, including libudfread 1.2.0 | 1.4.0 | LGPL-2.1-or-later |
| uchardet | 0.0.8 | MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later (used under LGPL-2.1-or-later) |

System libraries from Apple's SDKs are not redistributed.

Settings → About → Open Source Licences lists every library above, and each
library opens on its own page with its notice and full licence text. FFmpeg
and FreeType also ask for these credits: this software is based in part on
the work of the Independent JPEG Group, and portions of this software are
copyright © 2022 The FreeType Project (www.freetype.org). All rights reserved.

Vivid's player bridge (`VividPlayerCoreBase`, `VividPlayerCore` and the components beside them in `iosApp/iosApp/Playback/MPV/`) and the `VividMPVPlayer` adapter are Vivid's own code. Vivid’s additional Apple distribution permission does not extend to third-party code.

The retired package’s FFmpegBuild, standalone subtitle and Dolby Vision frameworks are no longer part of the source tree or either app target. Keep the notices matched to the pinned package rather than to the retired package’s inventory.

Source changes and successful device builds do not establish Apple distribution approval.
