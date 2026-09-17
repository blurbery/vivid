<p align="center">
  <img src="docs/branding/vivid-mark-silver.svg" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Third-Party Libraries</h1>
<p align="center">Playback, artwork and media dependencies.</p>
<p align="center"><a href="README.md">Home</a> · <a href="docs/README.md">Documentation</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses GPL-3.0-only with the [Apple distribution permission](LICENSE-APPLE-EXCEPTION). The [Vivid attribution terms](ATTRIBUTION.md) apply only to the covered material identified there. Third-party libraries retain their own licences.

| Component | Version / revision | Licence |
| --- | --- | --- |
| Apple media bridge | `8ad17ad38f2ba63576cd7b37b460a4362adb738e` | GPLv3; bundled upstream licence |
| Patched mpv Apple build | `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` | GPLv3 bundles; component licences remain upstream |
| CollectionHStack (tvOS Home rows) | `15baaaa759a0e252addae08431c79a49a25e4afc` | MIT |
| DifferenceKit (collection updates) | 1.3.0, `073b9671ce2b9b5b96398611427a1f929927e428` | MIT |
| ThumbHash decoder | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |

The full version, source and rebuild inventory is maintained in the [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt), alongside the unchanged upstream licence texts. The app exposes these in Settings → About → Open Source Licences.

## Timestamp services

Vivid acknowledges [IntroDB](https://introdb.app) and [TheIntroDB](https://theintrodb.org) for community episode timestamps. Selected-file markers take priority. IntroDB is the primary public provider; TheIntroDB fills missing intro, recap or credits markers through public, unauthenticated HTTP lookups. These are external services, not bundled SDKs or databases. Both appear in the separate About → Acknowledgements section on iOS and tvOS; Open Source Licences retains the existing library texts.

TMDB is also credited for metadata and artwork in Acknowledgements. Its logo and attribution appear in Acknowledgements on both platforms, without a duplicate block on About. This product uses the TMDB API but is not endorsed or certified by TMDB.

The separate Acknowledgements page contains service credits, with library licence texts confined to Open Source Licences. Bundled acknowledgement artwork comes from the projects’ official sources:

- IntroDB: `https://introdb.app/favicon.svg`
- TheIntroDB: `https://theintrodb.org/logo-small.svg`
- TMDB: the existing `TMDbAttributionLogo` asset.

The logos identify their respective projects and are not presented as Vivid-owned artwork.


## Lucid Engine dependencies (iOS and tvOS)

`iosApp/project.yml` selects `edde746/mpv-build` at
`c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` (mpv 0.41.0 and FFmpeg 8.0.1,
with that repository's Apple patch series). The upstream package declares its
bundled mpv/FFmpeg frameworks GPLv3. Its pinned Package.swift records binary
checksums and the upstream repository contains the corresponding build sources.

The adapted Apple media bridge retains its original source notices and GPLv3 licence. Exact upstream origin, revision, licence text and Vivid’s adaptations remain in the [bundled provenance and acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt). Vivid’s additional Apple distribution permission does not extend to third-party code. `VividMPVPlayer` is Vivid-owned adapter code.

The retired package’s FFmpegBuild and vendored subtitle frameworks are no longer part of the source tree or either app target. Lucid resolves media, subtitle, font and rendering dependencies through the pinned MPVKit manifest, which records each binary URL and checksum. Keep transitive notices matched to those inputs rather than reusing the retired package’s version inventory.

The device-tested libmpv also includes Vivid’s [audio EOF recovery patch](patches/mpv/0001-avfoundation-resume-after-audio-eof.patch). The [Lucid guide](docs/cores/player-engine.md#builds-and-native-audio-patch) records its build procedure and the distinction from a fresh package resolution. Source cleanup and successful device builds do not establish Apple distribution approval.
