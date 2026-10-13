<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Lucid Engine build</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="player-engine.md">Lucid Engine</a> · <a href="lucid-engine-build-facts.md">Build facts</a></p>

---

Vivid's own build pipeline for Lucid Engine's media libraries. It builds libmpv, FFmpeg, libass and dav1d from their upstream sources with Vivid's patch series, and checks every result against the recorded configuration of today's binaries. Nothing comes from a third-party build repository: the scripts, pins and patches all live in [`engine/`](../../engine).

> [!IMPORTANT]
> These binaries are interim. The app still links the pinned package described in [Lucid Engine](player-engine.md#builds-and-native-audio-patch), and the pipeline runs only on the `experiment/lucid-engine-build` branch. Upstream mpv has no `avfoundation` video output, so these builds cannot replace today's engine until Vivid's own engine patches land: video output, audio output and Dolby Vision.

## What it builds

| Library | Version | Built from | Licence as built | Patch series |
| --- | --- | --- | --- | --- |
| mpv (libmpv) | v0.41.0 (`41f6a645`) | upstream archive | LGPL-2.1-or-later (`-Dgpl=false`) | [`engine/patches/mpv`](../../engine/patches/mpv/series) |
| FFmpeg | n8.0.1 (`894da5ca`) | upstream archive | LGPL-2.1-or-later | [`engine/patches/ffmpeg`](../../engine/patches/ffmpeg/series) |
| libass | 0.17.5 (`4a05d812`) | upstream archive | ISC | none |
| dav1d | 1.5.3 (`b546257f`) | upstream archive | BSD-2-Clause | none |

Each build produces ten static frameworks: `Libmpv`, `Libass`, `Libdav1d` and the seven FFmpeg frameworks (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample` and `Libswscale`).

The remaining dependencies are not built here yet. They come from pinned release assets, at the versions and checksums today's package uses:

| Dependency | Version | Licence |
| --- | --- | --- |
| FreeType, FriBidi, HarfBuzz, libunibreak | 2.12.1, 1.0.12, 8.1.1, 6.1 | FTL, LGPL-2.1-or-later, MIT, Zlib |
| libplacebo | 7.351.0 | LGPL-2.1-or-later |
| Little CMS (lcms2) | 2.17 | MIT |
| libdovi | 3.3.2 | MIT |
| MoltenVK | 1.4.1 | Apache-2.0 |
| shaderc | 2025.5 | Apache-2.0 |
| uavs3d | 1.2 | BSD-3-Clause |
| libbluray | 1.4.0 | LGPL-2.1-or-later |
| uchardet | 0.0.8 | LGPL-2.1-or-later |

OpenSSL (`Libssl`, `Libcrypto`) is gone: FFmpeg uses Apple's Secure Transport for TLS. LuaJIT was only ever linked on macOS and is not needed.

## Running it

The [Lucid Engine build workflow](../../.github/workflows/lucid-engine.yml) runs on every push to `experiment/lucid-engine-build` that changes `engine/` or the workflow. It uses the `macos-26` runner with Xcode 26.6. One job per slice:

1. checks that every fetch is pinned and on the allowlist;
2. restores or downloads the pinned inputs and verifies each SHA-256;
3. builds dav1d, libass, FFmpeg and libmpv for the slice;
4. runs the provenance, licence, TLS and link checks below;
5. uploads the slice's frameworks, provenance report and logs.

A final job turns the slices into xcframeworks. Artefacts are kept for three days. A newer push cancels a running build.

The tool is [`engine/lucid.py`](../../engine/lucid.py), which needs Python 3.9 or later, the Xcode command-line tools and pkg-config. Build on CI rather than a personal Mac: a slice takes several minutes of full CPU. The steps are the same anywhere:

```sh
python3 engine/lucid.py check-allowlist
python3 engine/lucid.py fetch --downloads /path/to/downloads
python3 engine/lucid.py build --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py check --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py package --input /path/to/work/out --out /path/to/release
```

The work directory must be outside any Git repository and its path must not contain spaces. FFmpeg's version script would otherwise read the enclosing repository, and pkg-config and FFmpeg's configure split paths on spaces.

## Slices

| Slice (xcframework identifier) | SDK | Target |
| --- | --- | --- |
| `ios-arm64` | `iphoneos` | `arm64-apple-ios14.0` |
| `ios-arm64-simulator` | `iphonesimulator` | `arm64-apple-ios14.0-simulator` |
| `tvos-arm64` | `appletvos` | `arm64-apple-tvos14.0` |
| `tvos-arm64-simulator` | `appletvsimulator` | `arm64-apple-tvos14.0-simulator` |

Vivid links only arm64, so the pipeline builds no arm64e or x86_64 code. This changes two of the identifiers from today's package, where they are `tvos-arm64_arm64e` and `ios-arm64_x86_64-simulator`, and the tvOS simulator one from `tvos-arm64_x86_64-simulator`. `scripts/release/use-patched-libmpv.sh` hard-codes the old device identifiers, so it needs updating before it can use these binaries.

## Pins

[`engine/pins.ini`](../../engine/pins.ini) lists every input the build downloads, with its exact URL, version or commit, and SHA-256:

- `[source:*]`: the four upstream source archives. `lucid.py fetch` also reads the commit id GitHub embeds in each archive and compares it with the pinned commit.
- `[tool:*]`: meson 1.4.2 and ninja 1.12.1. pkg-config comes from the runner image.
- `[prebuilt:*]`: the interim release assets. `url` is the build input (headers, thin static libraries and pkg-config files for every slice). `xcframework_url` is the matching SwiftPM binary, for a package to use until the library is built here.
- `[toolchain]`: the Xcode version CI must use, the minimum OS (14.0) for every slice, and Vivid's own deployment targets (iOS 18.0, tvOS 26.0) for the test link.

`lucid.py check-allowlist` fails the run if any file in `engine/` or the workflow mentions a blocked project, if a URL points at a host that is not allowlisted, if a download is not one of the allowlisted upstream projects, if anything fetches outside `lucid.py`'s single download function, or if a workflow action is not pinned by commit SHA.

## Patch series

Each library has `engine/patches/<library>/series`, listing its patches in order with each file's SHA-256. The build applies them to the pristine source with `patch -p1 -F0` (no fuzz) and refuses any patch whose hash differs. There are no in-place source edits: every change to a source tree is a patch in a series.

| Library | Patch | What it does |
| --- | --- | --- |
| FFmpeg | `0001-securetransport-without-private-identity-api.patch` | Compiles the client-certificate path, which needs the private `SecIdentityCreate`, out of Secure Transport on iOS and tvOS. Server certificates are still checked against the system trust store. |
| FFmpeg | `0002-videotoolbox-request-metal-compatible-pixel-buffers.patch` | Asks VideoToolbox for Metal-compatible pixel buffers instead of the OpenGL ES or OpenGL compatibility flags, matching today's binaries. LGPL-2.1-or-later. |
| mpv | `0001-ad_spdif-recreate-spdif-muxer-on-reset.patch` | Upstream mpv commit `1388a453`, unchanged, with its upstream attribution: recreates the S/PDIF muxer after a seek and waits for a TrueHD major sync. |
| mpv | `0002-ao_avfoundation-build-for-ios-and-tvos.patch` | Lets upstream's AVFoundation audio output (`-Davfoundation=enabled`) compile for iOS and tvOS by keeping the macOS-only CoreAudio device code out of those builds, and builds the CoreFoundation string helpers it calls (`osdep/utils-mac.c`), which upstream builds only with the macOS `cocoa` feature. The output's `notification name:` log line is unchanged. macOS builds with `cocoa` are unchanged. LGPL-2.1-or-later. |

To add a patch, write it against the pristine source (or the previous patch in the series), add its SHA-256 and file name to the end of the `series` file, and push. The build fails if the files a series changes differ from the files its patches name.

## Configuration

The configuration lives in [`engine/config/`](../../engine/config) as plain lists, so it can be compared line by line with the [build facts](lucid-engine-build-facts.md):

| File | Contents |
| --- | --- |
| `ffmpeg-configure.txt` | FFmpeg's `configure` arguments, in today's order, with each decided change marked |
| `mpv-meson.txt` | mpv's meson options, likewise |
| `libass-meson.txt`, `dav1d-meson.txt` | libass and dav1d meson options |
| `expected-mpv-features.txt` | the mpv feature list every slice must report |
| `expected-ffmpeg-components.txt` | every FFmpeg decoder, encoder, demuxer, muxer, parser, bitstream filter, hwaccel, protocol and filter every slice must enable, and no others |
| `expected-ffmpeg-config.txt` | external libraries FFmpeg must enable or disable |
| `app-link.txt` | the system frameworks and libraries the link checks use, as Vivid's app targets link them |

Compilers come from the selected Xcode (`/usr/bin/clang`). Every library gets the same flags: `-arch arm64 -isysroot <SDK> -target <triple> <version-min flag>`, plus `-DHAVE_FORK=0` on tvOS and `-lc++` when linking. Meson projects get them through a generated cross file. FFmpeg gets them through `CFLAGS`, `CPPFLAGS` and `LDFLAGS`, as today. Libraries install under the prefix `/lucid-engine` and are staged with `DESTDIR`, so no build-machine path appears in the configuration strings.

### Differences from today's binaries

| Area | Today | This pipeline | Why |
| --- | --- | --- | --- |
| Slices | arm64 plus arm64e (tvOS device) and x86_64 (simulators); also Catalyst, macOS and visionOS | arm64 only, iOS and tvOS | Vivid links only arm64 on iPhone, iPad and Apple TV |
| mpv licence | `-Dgpl=true` | `-Dgpl=false` | Decided: LGPL-2.1-or-later libmpv |
| mpv options | `-Dmoltenvk=enabled -Dvo-avfoundation=enabled` | left out | Both exist only with third-party mpv patches, and upstream meson rejects them |
| mpv features | include `gpl`, `moltenvk` and `vo-avfoundation` | without those three | Follows from the two rows above |
| FFmpeg licence | `--enable-gpl --enable-version3` (GPL version 3 or later) | neither (LGPL version 2.1 or later) | Decided |
| FFmpeg TLS | OpenSSL 3.3.5 | Secure Transport, with the patch above | Decided |
| FFmpeg components | as listed in the facts | without the `delogo` filter, the `whip` muxer and the `dtls`, `ffrtmpcrypt`, `rtmpe` and `rtmpte` protocols | GPL-only filter; the others need OpenSSL |
| FFmpeg and libdovi | `-I` and `-L ... -ldovi` for a Dolby Vision patch | not passed | No Dolby Vision patch in the series yet; libplacebo still links libdovi |
| libass | three performance patches | upstream, unpatched | Decided |
| dav1d | third-party prebuilt | built from source, same options | Part of this pipeline |
| VideoToolbox Metal key | unrecorded source edit | patch `0002` | Every source change must be a patch |
| pkg-config search path | dependencies, then the build machine's default path | dependencies and two files describing the SDK's own zlib and libxml2 | Keeps the build machine's libraries out of feature detection |
| FFmpeg version string | `n8.0.1` | `8.0.1` | A release archive has no Git tag; changing it would need a source edit |
| mpv version string | `v0.41.0-dirty` | `v0.41.0` | Built from the release archive |
| Minimum OS | 14.0 for these four libraries | 14.0 | Unchanged |

Kept as today, for parity:

- Framework and module names, `[system]` module maps with the umbrella directory `"."` and `export *`, the same header exclusions, and the same `Headers/` layout, including FFmpeg's internal headers and `config.h`.
- Info.plist keys and values: `com.mpvkit.<Name>` bundle identifiers, version `87.88.520` and `MinimumOSVersion` `100.0`. Whether to change the identifiers is still open (facts section 6, item 5).
- The Libavutil module still fails to import, because `hwcontext_amf.h`, `hwcontext_drm.h`, `hwcontext_mediacodec.h` and `hwcontext_oh.h` are not excluded. Vivid reaches `avformat_configuration` by symbol name, which still works.

## Outputs

Each slice job uploads `lucid-engine-slice-<slice>` with:

- `frameworks/<Name>.framework`: static archive, `Headers/`, `Modules/module.modulemap` and `Info.plist`;
- `provenance.json` and `provenance.md`;
- `logs/`: the build output of each library, plus FFmpeg's `config.log` and meson's logs.

The packaging job uploads `lucid-engine-xcframeworks` with:

- `<Name>.xcframework.zip` for each of the ten frameworks, with `<Name>.xcframework/` as the zip's root. The zips are written with fixed timestamps and ordering, so identical frameworks give identical zips;
- `SHA256SUMS`: the SHA-256 of each zip, which is also its SwiftPM checksum;
- `provenance/`: each slice's report.

## Provenance and checks

`lucid.py build` records the toolchain (Xcode, SDK, clang, meson, ninja, pkg-config, make), the repository commit, the SHA-256 of `pins.ini`, every source archive with its hash and embedded commit, every applied patch with its hash, the pristine and patched tree digests, the FFmpeg configure arguments and the mpv meson options. `lucid.py check` then verifies the slice and adds its results:

- **Patched trees:** each source tree is unchanged by the build, and equals a fresh extraction of the pristine archive with the series applied again.
- **Inputs:** archive hashes and commits match `pins.ini`, and the applied patches match the series.
- **FFmpeg:**
  - The configuration in `config.h` and the string `avformat_configuration()` returns (read from the `Libavformat` object that defines it) both equal the configured arguments.
  - The configuration contains `--enable-securetransport` and none of `--enable-gpl`, `--enable-version3`, `--enable-openssl` or `delogo`.
  - Every library's licence string is `LGPL version 2.1 or later`, and `CONFIG_GPL`, `CONFIG_VERSION3` and `CONFIG_OPENSSL` are 0.
  - The enabled components match `expected-ffmpeg-components.txt` exactly, and so do the filter registry symbols `Libavfilter` defines, which is the form the build facts record. (`scale2ref` appears only as a symbol: `vf_scale.o` defines it, but the configure line has never enabled it.)
- **Symbols:**
  - No framework has OpenSSL symbols, references `_SecIdentityCreate` or defines the `delogo` filter.
  - `Libavformat` defines `_avformat_configuration`.
  - `Libavcodec` references `kCVPixelBufferMetalCompatibilityKey` and neither OpenGL compatibility key.
- **mpv:**
  - The recorded meson options match, with `-Dgpl=false` and no `-Dgpl=true` in the binary.
  - The feature list matches `expected-mpv-features.txt`.
  - The binary contains the text of mpv patch `0001`.
  - The client API version is 2.5, with the four expected headers.
- **libass and dav1d:** the versions are 0.17.5 (`0x01705000`) and API 7.0.0, and both archives contain their arm64 assembly.
- **Form:** every framework binary is arm64 only, built for the slice's platform with minimum OS 14.0. Info.plist values and module maps match, and the FFmpeg header counts match today's (26, 3, 5, 6, 109, 3 and 3).
- **Linkability:**
  - Symbol closure: every undefined symbol in every built and pinned archive is defined by another archive in the link set, by the compiler runtime, or by a public `.tbd` stub in the SDK. Only `___dso_handle` and the Objective-C selector stubs (`_objc_msgSend$<selector>`), which the linker synthesises, are exempt. Every SDK symbol must come from a framework or library in `app-link.txt`, following re-exports, or from libSystem or libobjc.
  - Test link: a small C program that calls `mpv_create`, `mpv_initialize`, `mpv_terminate_destroy` and `avformat_configuration` links, dead-stripped and without forced whole-archive loading, against the ten new frameworks, the twelve pinned prebuilt archives and `app-link.txt`, at Vivid's own deployment targets (iOS 18.0, tvOS 26.0).
  - `Libmpv` keeps the AVFoundation output's `notification name:` log line, which Vivid's adapter reads.

The summary of each slice also appears on the workflow run page.

## Still to do

- Vivid's own engine patches: an `avfoundation` video output, the native audio output changes Vivid relies on today, and Dolby Vision conversion. Until they exist, these builds cannot be linked into a shipping app.
- Building the remaining dependencies from source, starting with the ones that carry the most code (libplacebo, shaderc and MoltenVK).
- A Swift package that serves these xcframeworks, updating `use-patched-libmpv.sh` for the new slice identifiers, and deciding the bundle identifiers.
- Licence files and notices for the LGPL FFmpeg and libmpv and the removal of OpenSSL (`THIRD_PARTY_NOTICES.md` and the in-app licences) once the app links these builds.
