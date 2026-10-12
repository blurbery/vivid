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
| Apple media bridge (adapted from `edde746/plezy`) | `8ad17ad38f2ba63576cd7b37b460a4362adb738e` | GPL-3.0; bundled upstream licence. Vivid's Apple distribution permission does not apply |
| Lucid media engine package (`edde746/mpv-build`, product `MPVKit`) | `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` | GPLv3 as built; component licences [below](#lucid-engine-dependencies-ios-and-tvos) |
| CollectionHStack (tvOS Home rows) | `15baaaa759a0e252addae08431c79a49a25e4afc` | MIT |
| DifferenceKit (CollectionHStack dependency) | 1.3.0, `073b9671ce2b9b5b96398611427a1f929927e428` | Apache-2.0 |
| ThumbHash decoder (adapted) | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |
| tvOS media catalog sample code (adapted, Apple) | 2024 sample | Apple sample code licence (MIT-style) |
| Go Noto Current font | 2.012, `go-noto-universal` `0f4be64` | SIL Open Font License 1.1 |

This file is the full inventory of third-party components in both apps. The [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt) and the unchanged upstream licence texts beside it are shown in Settings → About → Open Source Licences; keep them matched to this list.

## Timestamp services

Vivid acknowledges [IntroDB](https://introdb.app) and [TheIntroDB](https://theintrodb.org) for community episode timestamps. Selected-file markers take priority. IntroDB is the primary public provider; TheIntroDB fills missing intro, recap or credits markers through public, unauthenticated HTTP lookups. These are external services, not bundled SDKs or databases. Both appear in the separate About → Acknowledgements section on iOS and tvOS; Open Source Licences retains the existing library texts.

TMDB is also credited for metadata and artwork in Acknowledgements. Its logo and attribution appear in Acknowledgements on both platforms, without a duplicate block on About. This product uses the TMDB API but is not endorsed or certified by TMDB.

The separate Acknowledgements page contains service credits, with library licence texts confined to Open Source Licences. Bundled acknowledgement artwork comes from the projects’ official sources:

- IntroDB: `https://introdb.app/favicon.svg`
- TheIntroDB: `https://theintrodb.org/logo-small.svg`
- TMDB: the existing `TMDbAttributionLogo` asset, and the Primary Short logo from `https://www.themoviedb.org/about/logos-attribution` as the `TMDbRatingMark` asset shown beside TMDB ratings on detail pages.

The logos identify their respective projects and are not presented as Vivid-owned artwork.

## Server and service names

Silo, Emby, Jellyfin, Plex, Kodi, Trakt, MDBList, OpenSubtitles and TMDB are trademarks of their respective owners. Vivid shows the Silo, Emby and Jellyfin names and logos to identify the servers it connects to, the MDBList, OpenSubtitles and TMDB names (and the TMDB logo, as its attribution requires) to identify the services it connects to, and the Plex, Kodi, Trakt, Emby and Jellyfin logos on the MDBList plugin page to show apps that MDBList works with (Vivid does not connect to Plex, Kodi or Trakt). Studios & Networks shows studio and network logos supplied by TMDb at runtime; none are bundled with the app. All of these names and logos belong to their owners, and Vivid is an independent app that is not endorsed by any of them. The Jellyfin project publishes its logo artwork under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The Silo wordmark is covered by the Silo brand-asset notice in `iosApp/iosApp/Assets.xcassets/NOTICE`.

## Fonts

Both apps bundle the Go Noto Current font (version 2.012, from the go-noto-universal project), copyright The Noto Project Authors and licensed under the SIL Open Font License 1.1. Noto is a trademark of Google LLC.

## Lucid Engine dependencies (iOS and tvOS)

`iosApp/project-ios.yml` and `iosApp/project.yml` pin `edde746/mpv-build` at
`c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` and link its `MPVKit` product. This
is not the separate `mpvkit/MPVKit` project. Its `Package.swift` records the URL
and SHA-256 checksum of every binary, and `versions.json` records the upstream
pins. The package builds mpv with `-Dgpl=true` and FFmpeg with `--enable-gpl`
and `--enable-version3`, so the media frameworks are distributed under GPLv3.
The package supplies static libraries, which are linked into the app executable.

| Library | Version | Licence | Prebuilt by |
| --- | --- | --- | --- |
| mpv (libmpv) | 0.41.0 | GPL-2.0-or-later as built; most files LGPL-2.1-or-later | `edde746/mpv-build` |
| FFmpeg (libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale) | 8.0.1 | GPL-3.0-or-later as built; most files LGPL-2.1-or-later | `edde746/mpv-build` |
| libass | 0.17.5 | ISC | `edde746/mpv-build` |
| FreeType | 2.12.1 | FreeType Licence | `mpvkit/libass-build` 0.17.4 |
| FriBidi | 1.0.12 | LGPL-2.1-or-later | `mpvkit/libass-build` 0.17.4 |
| HarfBuzz | 8.1.1 | MIT | `mpvkit/libass-build` 0.17.4 |
| libunibreak | 6.1 | zlib | `mpvkit/libass-build` 0.17.4 |
| libplacebo | 7.351.0 | LGPL-2.1-or-later | `mpvkit/libplacebo-build` |
| Little CMS | 2.17 | MIT | `mpvkit/lcms2-build` |
| libdovi (`dolby_vision` crate and its Rust dependencies) | 3.3.2 | MIT; dependencies MIT, Apache-2.0 or zlib | `mpvkit/libdovi-build` |
| MoltenVK, including SPIRV-Cross, SPIRV-Tools and cereal | 1.4.1 | Apache-2.0; cereal BSD-3-Clause | `mpvkit/moltenvk-build` |
| shaderc, including glslang and SPIRV-Tools | 2025.5 | Apache-2.0; glslang BSD-3-Clause, BSD-2-Clause, MIT and Apache-2.0 | `mpvkit/libshaderc-build` |
| dav1d | 1.5.3 | BSD-2-Clause | `edde746/libdav1d-build` |
| uavs3d | upstream `master` at build time | BSD-3-Clause | `mpvkit/libuavs3d-build` 1.2.1-fix |
| OpenSSL (libssl, libcrypto) | 3.3.5 | Apache-2.0 | `mpvkit/openssl-build` |
| libbluray, including libudfread | 1.4.0 | LGPL-2.1-or-later | `mpvkit/libbluray-build` |
| uchardet | 0.0.8 | MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later | `mpvkit/libuchardet-build` |

LuaJIT is in the package for macOS only and is not part of either app. System
libraries from Apple's SDKs are not redistributed.

`edde746/mpv-build` holds the build driver, upstream pins and patch series for
mpv, FFmpeg and libass. The other libraries are prebuilt by the build
repositories listed above from the upstream sources at those versions.

The adapted Apple media bridge files carry provenance headers that name the upstream repository and revision; the upstream files had no individual notices. Plezy's GPL-3.0 licence text is bundled, and Vivid's adaptations are described in the [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt). Vivid’s additional Apple distribution permission does not extend to third-party code. `VividMPVPlayer` is Vivid-owned adapter code.

The retired package’s FFmpegBuild, standalone subtitle and Dolby Vision frameworks are no longer part of the source tree or either app target. Keep the notices matched to the pinned package rather than to the retired package’s inventory.

The device-tested libmpv also includes Vivid’s [audio EOF recovery patch](patches/mpv/0001-avfoundation-resume-after-audio-eof.patch). The [Lucid guide](docs/cores/player-engine.md#builds-and-native-audio-patch) records its build procedure and the distinction from a fresh package resolution. Source cleanup and successful device builds do not establish Apple distribution approval.
