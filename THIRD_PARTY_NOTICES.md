<p align="center">
  <img src="docs/branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Third-Party Libraries</h1>
<p align="center">Playback, artwork and media dependencies.</p>
<p align="center"><a href="README.md">Home</a> · <a href="docs/README.md">Documentation</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid and VividKit application code use Apache-2.0. Third-party libraries retain their own licences.

| Component | Version / revision | Licence |
| --- | --- | --- |
| FFmpegBuild | `421e13be7061de67d91b85ac34a6b22a002b164f` | LGPL-2.1; embedded FFmpeg and codec dependencies retain the licences recorded below |
| libass | 0.17.1 | ISC |
| FreeType | 2.13.2 | FreeType License |
| FriBidi | 1.0.12 | LGPL-2.1-or-later |
| HarfBuzz | 5.3.1 | MIT |
| ThumbHash decoder | `a652ce6ed691242f459f468f0a8756cda3b90a82` | MIT |

The full version, source and rebuild inventory is maintained in the [bundled acknowledgements](iosApp/Resources/OpenSourceLicenses/README.txt), alongside the unchanged upstream licence texts. The app exposes these in Settings → About → Open Source Licenses.

FFmpeg remains a set of separate dynamic frameworks. Its binary packaging retains the `AetherLib` prefix, which identifies the packaged FFmpeg frameworks. The exact build excludes GPL and nonfree FFmpeg features. VividKit links only the four standalone subtitle/font frameworks from the pinned FFmpegKit source tree; it does not link FFmpegKit's playback code or mpv.

The subtitle/font frameworks are vendored in [VividKit/Vendor](VividKit/Vendor), with their provenance and licence texts. Their simulator and device slices are available as separately replaceable SwiftPM binary targets. External distribution must preserve source and relinking rights for the LGPL components; an Apache licence on Vivid's code does not relicense those dependencies.
