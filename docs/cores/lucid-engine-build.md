<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Lucid Engine build</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="player-engine.md">Lucid Engine</a> · <a href="lucid-engine-architecture.md">Architecture</a> · <a href="lucid-engine-build-facts.md">Build facts</a> · <a href="lucid-engine-libs-build-facts.md">Library build facts</a> · <a href="../playback/lucid-engine-patch-spec.md">Patch specification</a></p>

---

Vivid's own build pipeline for Lucid Engine's media libraries. It builds every library the engine links, from libmpv and FFmpeg down to FreeType and MoltenVK, from their upstream sources with Vivid's patch series, and checks every result against the recorded configuration of today's binaries. Nothing comes from a third-party build repository: the scripts, pins and patches all live in [`engine/`](../../engine). The only prebuilt code in the engine is the Rust standard library inside libdovi, from the Rust project's pinned `rust-std` archives (see [libdovi](#libdovi)).

> [!IMPORTANT]
> The app links these builds: both platform specs pin release [`0.1.0`](https://github.com/blurbery/lucid-engine/releases/tag/v0.1.0) of the Swift package, which serves them, every library built from its upstream source, with Rust's prebuilt standard library inside libdovi as the one exception (see [Publishing the package](#publishing-the-package) and [Lucid Engine](player-engine.md#builds)). The [workflow](../../.github/workflows/lucid-engine.yml) runs the pipeline on pushes to `main`, `experiment/lucid-engine-build` and the engine implementers' `experiment/lucid-engine-*` branches that change `engine/` or the workflow, and on pull requests that do. Upstream mpv has no `avfoundation` video output. Vivid's own engine patches are all in the series: the audio output (mpv `0010` to `0016`), the video output (mpv `0020` to `0025`), the decoder work (FFmpeg `0010` to `0012`, mpv `0040`) and libass's event render cache (libass `0001`, `0002` and `0010`). They pass the host tests here, but the device checks of the patch specification (9.5, 12.7 and 13.7) have not been run yet.

## What it builds

| Library | Version | Built from | Licence as built | Patch series |
| --- | --- | --- | --- | --- |
| mpv (libmpv) | v0.41.0 (`41f6a645`) | upstream archive | LGPL-2.1-or-later (`-Dgpl=false`) | [`engine/patches/mpv`](../../engine/patches/mpv/series) |
| FFmpeg | n8.0.1 (`894da5ca`) | upstream archive | LGPL-2.1-or-later | [`engine/patches/ffmpeg`](../../engine/patches/ffmpeg/series) |
| libass | 0.17.5 (`4a05d812`) | upstream archive | ISC | [`engine/patches/libass`](../../engine/patches/libass/series) |
| dav1d | 1.5.3 (`b546257f`) | upstream archive | BSD-2-Clause | none |
| libdovi (the `dolby_vision` crate's C API) | 3.3.2 (`4fd2b223`) | upstream archive, Rust 1.98.0 and cargo-c 0.10.25 | MIT | [`engine/patches/libdovi`](../../engine/patches/libdovi/series) |
| FreeType | 2.12.1 (`e8ebfe98`) | upstream archive (GitHub mirror, tag `VER-2-12-1`) | FTL | none |
| FriBidi | 1.0.12 (`6428d846`) | upstream archive | LGPL-2.1-or-later | none |
| HarfBuzz | 8.1.1 (`1d665c2b`) | upstream archive | MIT | none |
| libunibreak | 6.1 (`304585d8`) | upstream release tarball | Zlib | none |
| Little CMS (lcms2) | 2.17 (`51763476`) | upstream archive | MIT | none |
| uavs3d | 1.2 (`0e20d2c2`) | upstream archive | BSD-3-Clause | [`engine/patches/uavs3d`](../../engine/patches/uavs3d/series) |
| libbluray, with libudfread 1.2.0 | 1.4.0 (`9f07fbb2`) | upstream release tarball | LGPL-2.1-or-later | [`engine/patches/libbluray`](../../engine/patches/libbluray/series) |
| uchardet | 0.0.8 (`ae6302a0`) | upstream release tarball | LGPL-2.1-or-later | none |
| shaderc, with glslang, SPIRV-Tools and SPIRV-Headers | 2025.5 (`c4b0af6c`) | upstream archives | Apache-2.0 (glslang: BSD-3-Clause and others; SPIRV-Headers: MIT) | none |
| MoltenVK, with SPIRV-Cross, SPIRV-Tools, SPIRV-Headers, Vulkan-Headers and cereal | 1.4.1 (`db445ff2`) | upstream archives | Apache-2.0 (cereal: BSD-3-Clause; Vulkan-Headers: Apache-2.0 or MIT) | none |
| libplacebo, with its five submodules | 7.351.0 (`3188549f`) | upstream archives | LGPL-2.1-or-later | none |

Each build produces 21 static frameworks and one static library: `Libmpv`, `Libass`, `Libdav1d`, `Libdovi`, the seven FFmpeg frameworks (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample` and `Libswscale`), `Libfreetype`, `Libfribidi`, `Libharfbuzz`, `Libunibreak`, `lcms2`, `Libuavs3d`, `Libbluray`, `Libuchardet`, `Libshaderc_combined` and `Libplacebo`, and `MoltenVK`, which ships, as today, as a bare static library (`libMoltenVK.a`) without headers or a module.

OpenSSL (`Libssl`, `Libcrypto`) is gone: FFmpeg uses Apple's Secure Transport for TLS. LuaJIT was only ever linked on macOS and is not needed.

## Running it

The [Lucid Engine build workflow](../../.github/workflows/lucid-engine.yml) runs on every push to `main`, `experiment/lucid-engine-build` or any branch matching `experiment/lucid-engine-*` that changes `engine/` or the workflow. It also starts on every pull request, where a `changes` job on a standard Ubuntu runner skips the macOS build, test and packaging jobs unless `engine/` or the workflow changed, or it can't compare the pull request with its base commit, so its `Lucid Engine result` check always reports. Engine implementers work on their own `experiment/lucid-engine-*` branches, so their patches are built and checked the same way. Each ref has its own concurrency group, so a newer push cancels only that ref's running build. Its build, test and packaging jobs use only GitHub's public `macos-26` runners, with Xcode 26.6; the change check and result jobs use a standard Ubuntu runner. One job per slice:

1. checks that every fetch is pinned and on the allowlist;
2. restores or downloads the pinned inputs and verifies each SHA-256;
3. restores the slice's [dependency cache](#dependency-cache);
4. builds libdovi, then the eleven dependencies (or reuses their cached builds), then dav1d, libass, FFmpeg and libmpv for the slice, and saves the dependency cache when it built any dependency, even if a later step fails;
5. builds and runs the audio output's test vectors on the runner, from the mpv tree it has just patched;
6. runs the provenance, licence, TLS, libdovi, dependency, decoder, audio output, video output, reproducibility and link checks below;
7. builds and runs the video output tests for the build host, from the patched mpv tree (in the `ios-arm64-simulator` job only, so once per run, and also when the checks failed);
8. builds and runs the decoder tests from the slice's patched FFmpeg and libdovi trees on the build host, including an end-to-end test of FFmpeg's VideoToolbox glue against a fake VideoToolbox;
9. uploads the slice's frameworks, provenance report and logs.

Alongside them, the libdovi C API test job builds libdovi for the runner itself, unpatched and patched, and runs the malformed RPU corpus through both (see [libdovi](#libdovi)), and the libass host test job builds libass for the runner from upstream, from each prefix of its series and from the whole series under AddressSanitizer, and runs a scenario corpus through every build (see [libass](#libass)). A packaging job, which waits for every slice and both test jobs, turns the slices into xcframeworks, and a last result job fails the run when any job failed or was cancelled. Artefacts are kept for three days.

The tool is [`engine/lucid.py`](../../engine/lucid.py), which needs Python 3.9 or later, the Xcode command-line tools and pkg-config. Build on CI rather than a personal Mac: a slice takes several minutes of full CPU. The steps are the same anywhere:

```sh
python3 engine/lucid.py check-allowlist
python3 engine/lucid.py fetch --downloads /path/to/downloads
python3 engine/lucid.py build --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads \
  [--cache /path/to/dependency-cache]
python3 engine/lucid.py test-audio --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py check --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py test --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py test-vo --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py package --input /path/to/work/out --out /path/to/release
python3 engine/lucid.py test-libdovi --work /path/to/libdovi-test --downloads /path/to/downloads
python3 engine/lucid.py test-libass --work /path/to/libass-test --downloads /path/to/downloads
python3 engine/publish_package.py --run <run id> --version <version> --package /path/to/lucid-engine
```

The last command prepares a release of the Swift package from a green run's artefacts (see [Publishing the package](#publishing-the-package)). The work directory must be outside any Git repository and its path must not contain spaces. FFmpeg's version script would otherwise read the enclosing repository, and pkg-config and FFmpeg's configure split paths on spaces. `test-libdovi` has neither restriction and takes a few minutes of one core; `fetch --only rust:,tool:cargo-c,source:libdovi` fetches just what it needs. `test-libass` needs a work path without spaces (pkg-config) but may be inside a repository; it takes about two minutes on an Apple silicon Mac, most of it building HarfBuzz, and `fetch --only tool:meson,tool:ninja,tool:cmake,source:libass,source:freetype,source:fribidi,source:harfbuzz` fetches what it needs (CMake is unpacked with the other build tools but not used).

## Slices

| Slice (xcframework identifier) | SDK | Target |
| --- | --- | --- |
| `ios-arm64` | `iphoneos` | `arm64-apple-ios14.0` |
| `ios-arm64-simulator` | `iphonesimulator` | `arm64-apple-ios14.0-simulator` |
| `tvos-arm64` | `appletvos` | `arm64-apple-tvos14.0` |
| `tvos-arm64-simulator` | `appletvsimulator` | `arm64-apple-tvos14.0-simulator` |

Vivid links only arm64, so every slice the pipeline ships is arm64 only, with no arm64e or x86_64 code. The one place x86_64 is compiled at all is MoltenVK's upstream simulator build, which also builds x86_64; the pipeline thins that library to arm64 before staging it (see [Dependencies](#dependencies)). This changes two of the identifiers from today's package, where they are `tvos-arm64_arm64e` and `ios-arm64_x86_64-simulator`, and the tvOS simulator one from `tvos-arm64_x86_64-simulator`. The old install script, `scripts/release/use-patched-libmpv.sh`, hard-coded the old device identifiers; it has been removed, and the [Swift package](#publishing-the-package) serves these slices instead.

## Pins

[`engine/pins.ini`](../../engine/pins.ini) lists every input the build downloads, with its exact URL, version or commit, and SHA-256:

- `[source:*]`: the 16 upstream source archives, one per library. `lucid.py fetch` also reads the commit id GitHub embeds in each archive and compares it with the pinned commit. Three are the projects' own release tarballs: libunibreak's (which adds upstream's generated `configure` to the tag's tree, so no autotools are needed) and libbluray's (which carries libudfread 1.2.0), marked `release_tarball = yes` because they embed no commit, and uchardet's, which embeds the tag's commit. `minimum_os` gives a library's deployment target where it differs from 14.0. libdovi's entry also pins the SHA-256 of the `Cargo.lock` in the archive's `dolby_vision` folder (`7400fd25…`); fetch checks it, then downloads every crate that lock file lists (83, development dependencies included, because Cargo resolves them all) from static.crates.io and checks each against the lock file's checksum, which is the SHA-256 of the `.crate` file.
- `[part:*]`: further upstream archives a source tree is assembled from, each extracted into the folder its source's `parts` names: libplacebo's five submodules (`3rdparty/`), the glslang, SPIRV-Tools and SPIRV-Headers revisions of shaderc's `DEPS` file (`third_party/`), and the SPIRV-Cross, SPIRV-Tools, SPIRV-Headers, Vulkan-Headers and cereal revisions of MoltenVK's `ExternalRevisions/` folder (`External/`, where MoltenVK's `fetchDependencies` script would put them). Their embedded commits are checked too.
- `[tool:*]`: meson 1.4.2, ninja 1.12.1, CMake 4.4.3 (Kitware's macOS release, checked against Kitware's published SHA-256) and cargo-c 0.10.25 (the macOS release binary; it embeds cargo 0.99.0, Rust 1.98's). pkg-config comes from the runner image.
- `[rust:*]`: Rust 1.98.0 stable from static.rust-lang.org: `rustc`, `cargo` and the standard library for the runner (`aarch64-apple-darwin`) and for each slice (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-tvos`, `aarch64-apple-tvos-sim`). The hashes are the `xz_hash` values of that release's channel manifest. `lucid.py` unpacks the components itself, without rustup.
- `[toolchain]`: the Xcode version CI must use, the default minimum OS (14.0), Vivid's own deployment targets (iOS 18.0, tvOS 26.0) for the test link, and `source_date_epoch` (below).

Every download goes through `lucid.py`'s single download function, from these projects and hosts only, all upstream: FFmpeg, mpv-player, libass, videolan, mesonbuild, ninja-build, Kitware (CMake), quietvoid (libdovi's `dovi_tool`), lu-zero (cargo-c), freetype, fribidi, harfbuzz, adah1972 (libunibreak), mm2 (Little CMS), haasn (libplacebo), fastfloat, Dav1dde (glad) and pallets (jinja, MarkupSafe) for libplacebo's submodules, KhronosGroup, USCiLab (cereal), google/shaderc and uavs3 on GitHub; `download.videolan.org/pub/videolan/libbluray/`; `www.freedesktop.org/software/uchardet/releases/`; `static.rust-lang.org/dist/`; and `static.crates.io/crates/`. No third-party binary is downloaded. The libdovi build itself runs offline: Cargo uses the verified crates as a vendored directory source with `--frozen`, so it resolves and downloads nothing. The libass host test has no pins of its own: it builds FreeType, FriBidi and HarfBuzz for the runner from the same `[source:*]` archives and patch series as the slices (see [Host tests](#host-tests)).

`lucid.py check-allowlist` fails the run if any file in `engine/` or the workflow mentions a blocked project (third-party build repositories among them), if a URL points at a host that is not allowlisted, if a download is not one of the allowlisted upstream projects, if anything fetches outside `lucid.py`'s single download function, if a pin has no SHA-256, if a source names a part that has no pin (or a part is unused), if the sources differ from the build order or a source has no patch series, or if a workflow action is not pinned by commit SHA.

## Patch series

Each library has `engine/patches/<library>/series`, listing its patches in order with each file's SHA-256. The build applies them to the pristine source with `patch -p1 -F0` (no fuzz) and refuses any patch whose hash differs. There are no in-place source edits: every change to a source tree is a patch in a series.

| Library | Patch | What it does |
| --- | --- | --- |
| FFmpeg | `0001-securetransport-without-private-identity-api.patch` | Compiles the client-certificate path, which needs the private `SecIdentityCreate`, out of Secure Transport on iOS and tvOS. Server certificates are still checked against the system trust store. |
| FFmpeg | `0002-videotoolbox-request-metal-compatible-pixel-buffers.patch` | Asks VideoToolbox for Metal-compatible pixel buffers instead of the OpenGL ES or OpenGL compatibility flags, matching today's binaries. LGPL-2.1-or-later. |
| FFmpeg | `0010-videotoolbox-give-every-sample-an-explicit-size.patch` | Creates every sample handed to VideoToolbox with an explicit sample size, for every codec. VideoToolbox's Dolby Vision HEVC decoder fails samples without one. LGPL-2.1-or-later. |
| FFmpeg | `0011-videotoolbox-decode-dolby-vision-profiles-5-7-and-8-natively.patch` | Decodes HEVC with a usable Dolby Vision record of profile 5, 7 or 8 through VideoToolbox's Dolby Vision HEVC (`dvh1`) decoder. Profile 7 is presented as profile 8.1: rewritten record, RPUs converted by libdovi 3.3.2 (mode 2), no enhancement layer, and empty or truncated RPUs skipped before libdovi sees them. Profile 7 and 8 retry once as plain HEVC when VideoToolbox refuses the session. Adds the per-frame HDR metadata session properties. Decoded frames get FFmpeg's usual attachments from the stream's colour signalling, as before, at any thread count. The logic lives in its own file, `libavcodec/videotoolbox_dovi.c`. LGPL-2.1-or-later. |
| FFmpeg | `0012-hevcdec-log-repeated-dolby-vision-rpus-and-skipped-nal-units-at-verbose.patch` | Logs `Multiple Dolby Vision RPUs found in one AU. Skipping previous.` and `Skipping NAL unit %d` at verbose level instead of warning and info. LGPL-2.1-or-later. |
| mpv | `0001-ad_spdif-recreate-spdif-muxer-on-reset.patch` | Upstream mpv commit `1388a453`, unchanged, with its upstream attribution: recreates the S/PDIF muxer after a seek and waits for a TrueHD major sync. |
| mpv | `0002-ao_avfoundation-build-for-ios-and-tvos.patch` | Lets upstream's AVFoundation audio output (`-Davfoundation=enabled`) compile for iOS and tvOS by keeping the macOS-only CoreAudio device code out of those builds, and builds the CoreFoundation string helpers it calls (`osdep/utils-mac.c`), which upstream builds only with the macOS `cocoa` feature. The output's `notification name:` log line is unchanged. macOS builds with `cocoa` are unchanged. LGPL-2.1-or-later. |
| mpv | `0010-ad_spdif-derive-the-e-ac-3-carrier-rate-from-the-stream.patch` | Opens E-AC-3 passthrough at four times the stream's codec rate (4 x 48000 when unknown) instead of 192000 Hz for every stream, so 44.1 kHz E-AC-3 keeps its timing. AC-3 is unchanged. LGPL-2.1-or-later. |
| mpv | `0011-f_output_chain-wake-the-chain-after-a-hard-reset.patch` | Wakes the output chain at the end of `mp_output_chain_reset_harder`, so audio does not stall after an output reload or the passthrough fallback. LGPL-2.1-or-later. |
| mpv | `0012-ao_avfoundation-shared-centre-of-the-rebuilt-output.patch` | The AVFoundation audio output's shared centre, in plain C: the audio session rules with `manage-audio-session`, the process-wide passthrough block, the order of init's refusals, trace edges and the prefetch guard. LGPL-2.1-or-later. |
| mpv | `0013-ao_avfoundation-decoded-pcm-sink-with-a-bounded-tvos-mode.patch` | The decoded PCM sink's decisions: upstream's renderer behaviour on iOS and unbounded tvOS, and on tvOS with `max-lookahead` a bounded, timer-fed renderer queue with a fresh renderer after every reset. LGPL-2.1-or-later. |
| mpv | `0014-ao_avfoundation-start-up-supervision-and-clock-anchoring.patch` | Passthrough start-up: rate 1 once primed, engagement, one recovery seek with the first-start grace, slow-source extensions, fallback, and the start and resume anchoring that keeps video waiting for AirPlay audio. LGPL-2.1-or-later. |
| mpv | `0015-ao_avfoundation-ac-3-and-e-ac-3-passthrough.patch` | The passthrough sink's decisions: IEC 61937 unwrapping, the stream window and serving, filling, clocks, diagnostics, end-of-file resume and the fallback to PCM. LGPL-2.1-or-later. |
| mpv | `0016-ao_avfoundation-avfoundation-bindings-for-both-sinks.patch` | Replaces upstream's driver with the Objective-C bindings: driver and `ao-avfoundation-*` options (`max-lookahead` on tvOS only), the output's queue, `AVAudioSession`, the renderer and synchroniser, and `AVPlayer` with its resource loader. LGPL-2.1-or-later. |
| mpv | `0020-vo_avfoundation-presentation-timing-and-pacing.patch` | Video output, part 1: the playback rate estimator, the media-mode timebase servo, the CoreMedia timebase and frame pacing (readiness wait, deadline drops, recovery throttle). LGPL-2.1-or-later. |
| mpv | `0021-vo_avfoundation-pixel-kernels-geometry-and-pools.patch` | Video output, part 2: upload copies and the direct subtitle blends (vectorised with NEON on arm64, bit for bit equal to their scalar forms), the YUV subtitle composite in a fixed evaluation order, host layer pixel size and frame-space geometry, and the CoreVideo pools. LGPL-2.1-or-later. |
| mpv | `0022-vo_avfoundation-frame-path.patch` | Video output, part 3: software uploads and colour tags, pixel aspect, the Dolby Vision transfer repair, samples, and Picture in Picture composites that blend into the decoder's buffer and keep the changed rows, so each presented image carries its subtitle exactly once. A buffer that may be on screen is written only when it is presented again: a redraw's rows are prepared elsewhere and each changed row is written once, so the picture never passes through a state without its cue, and switching compositing off changes nothing on screen. LGPL-2.1-or-later. |
| mpv | `0023-vo_avfoundation-subtitles.patch` | Video output, part 4: every subtitle object drawn into one canvas (primary and secondary together), change tracking, dirty tracking and timed subtitle samples. LGPL-2.1-or-later. |
| mpv | `0024-vo_avfoundation-layers-and-observers.patch` | Video output, part 5: the host and subtitle layers, their renderers and timebase, the main-thread hops, the resize and app-state observers, and the layers' last release on the main thread. LGPL-2.1-or-later. |
| mpv | `0025-vo_avfoundation-add-the-video-output.patch` | Adds `vo=avfoundation` (meson feature `vo-avfoundation`, first in the video output list) with its `avfoundation-*` options and the VideoToolbox device it registers. LGPL-2.1-or-later. |
| mpv | `0040-vd_lavc-tolerate-a-short-burst-of-hardware-decoding-errors.patch` | Once hardware decoding has output a frame, a run of decoding errors ends it only after two keyframes fail to recover it or after 240 errors, instead of at the first error with `hwdec-software-fallback=yes`. Probing still falls back at once. LGPL-2.1-or-later. |
| libass | `0001-ass_font-improve-symbol-font-base-offset.patch` | Upstream libass commit `057a5334` ("ass_font: improve symbol font base offset", merged with libass pull request #946), unchanged, with its upstream attribution: works out a symbol-encoded font's base offset from its character map, the way GDI does, instead of always using `0xF000`, and looks up only characters up to U+00FF and from U+F020 to U+F0FF in such a font, so Webdings, Wingdings and similar fonts given non-Latin text place their glyphs as today's engine does. ISC. |
| libass | `0002-render-cache-rendered-events.patch` | Upstream libass pull request #951 ("render: cache rendered events", by kasper93), at its head commit `f96a521a`, unchanged, with its upstream attribution. The pull request was open when it was taken. Caches the finished images of events that do not depend on the time (no `\move`, `\fad`, `\t`, karaoke or scrolling effect), keyed by text, style, margins and a snapshot of every setting and track state the output depends on, within a 32 MiB budget. An unchanged sign with a vector clip, or a line with a background box, is then reported unchanged instead of changed on every frame. ISC. |
| libass | `0010-render-keep-unresolved-glyphs-per-event.patch` | Vivid's own patch on top of `0002`; see [libass](#libass). Keeps output with glyphs that no font could provide to the event that rendered it, which looks its own entry up first, keeps every entry a frame uses until the next frame has been rendered, so an event on screen reuses its entry however full the cache is, even when it draws nothing visible, renders such events once more after any font gains a fallback face, adds the event's Effect to the cache key, releases the cache whenever the state snapshot changes, and gives image clones their image's type. ISC. |
| libdovi | `0001-capi-return-an-error-instead-of-aborting-on-any-input.patch` | Makes every C API function return its normal error result instead of aborting the process, for any input (see [libdovi](#libdovi)). Valid input gives the same results. MIT, like libdovi. |
| libbluray | `0001-darwin-build-for-ios-and-tvos.patch` | Vivid's own patch, needed to build for iOS and tvOS, with the two effects the build facts record for today's binary (facts 3.10). DiskArbitration is linked only when the SDK has it (macOS); without it the mount point lookup for a block device is not performed and finds no mount point, and only CoreFoundation is linked. On iOS and tvOS the Java home lookup never runs `/usr/libexec/java_home` and behaves as if `vfork` had failed (it logs `vfork failed` and returns no Java home), so the binary references no `vfork`, `execl`, `dup2` or `waitpid`, as today's. macOS builds are unchanged. LGPL-2.1-or-later. |
| uavs3d | `0001-version-describe-tag-1.2-without-git-history.patch` | uavs3d's `version.sh` derives the build number and commit id from Git, which an archive build has not got. The patch fixes them for tag 1.2, so `version.h` holds today's `VER_BUILD 1`, `VERSION_STR "1.2.1"` and `VERSION_TYPE "release"`, the pkg-config version stays 1.2.1, and `VERSION_SHA1`, which `uavs3d_create` prints, is uavs3d's own commit for the tag (`0e20d2c2…`) instead of today's third-party build identifier. BSD-3-Clause, like uavs3d. |

FreeType, FriBidi, HarfBuzz, libunibreak, Little CMS, shaderc, MoltenVK, libplacebo and uchardet are built unpatched, like dav1d: their series files are empty. None needs a change to build with Xcode 26.6. Today's libplacebo carried upstream commit `a22f0dff` (a Python 3.14 fix for its Vulkan code generator, with no effect on the generated code), and today's shaderc two edits to SPIRV-Tools command-line tools that are not built; neither is needed here, because meson runs under Xcode's Python 3.9 and those tools are still not built.

The audio output patches add one module each, with the pure C decisions first and the Objective-C bindings last (`0016`), and each adds its own files to `meson.build`, so every stage of the series builds. The video output patches add their modules first (`0020` to `0024`, which `meson.build` does not build yet) and the output itself last (`0025`), which adds them all to `meson.build`. Vivid's own patches for the AVFoundation video and audio outputs, Dolby Vision and the other kept behaviour are written from the [patch specification](../playback/lucid-engine-patch-spec.md), in these number ranges: audio output mpv 0010 to 0019 (0010 to 0016 so far, including the E-AC-3 carrier rate and the output-chain wake), video output mpv 0020 to 0039 (0020 to 0025 so far), decoder work mpv 0040 to 0049 (0040 so far) and FFmpeg 0010 to 0029 (0010 to 0012 so far). libass takes upstream changes as `0001` to `0009` and Vivid's own from `0010`.

Each part was written on its own implementer branch, against the pristine source with the patches already on the pipeline branch, and the three were then merged into one series per library. Only one hunk needed regenerating: the `meson.build` hunk of `0025`, which follows the audio output's `meson.build` additions in the merged series and so moved from line 1525 to line 1532. Its content is unchanged, and the merged tree is identical to applying the original `0025` after the audio output patches. Every prefix of every series applies to the pristine source with `patch -p1 -F0` without offsets, fuzz or leftover files, and changes exactly the files its patches name.

To add a patch, write it against the pristine source (or the previous patch in the series), add its SHA-256 and file name to the end of the `series` file, and push. The build fails if the files a series changes differ from the files its patches name.

## libdovi

libdovi is the C API of the `dolby_vision` crate (Rust, MIT). Two callers in the engine hand it Dolby Vision RPUs taken straight from the media: libplacebo, which mpv calls for every frame that carries an RPU, and FFmpeg's profile 7 conversion in Vivid's Dolby Vision patch (FFmpeg `0011`). The [patch specification](../playback/lucid-engine-patch-spec.md) (5.13) sets the requirements.

### Built from source

- **Source and pins:** tag `libdovi-3.3.2` of `quietvoid/dovi_tool` (commit `4fd2b223`, archive SHA-256 `8ccb1922…`), its locked crates, Rust 1.98.0 and cargo-c 0.10.25, all pinned as above. Rust 1.98.0 ships a standard library for every slice's target, tvOS included, so no nightly and no `-Zbuild-std` is needed.
- **Build:** `cargo cinstall --release --frozen --library-type=staticlib --target <triple>` in the crate folder, with `IPHONEOS_DEPLOYMENT_TARGET` or `TVOS_DEPLOYMENT_TARGET` set to 14.0 and `--remap-path-prefix` keeping build paths out of panic locations. It is built first, so FFmpeg's and mpv's configure steps find its `dovi.pc` where libplacebo's pkg-config file requires it.
- **Form:** framework `Libdovi`, module `Libdovi`, with `Headers/rpu_parser.h`, as today. The header, the pkg-config name `dovi` and the 21 exported `dovi_*` functions are unchanged; `check` compares them, for every slice, with today's prebuilt as the last green run with the prebuilt recorded it in [`engine/config/expected-libdovi.txt`](../../engine/config/expected-libdovi.txt) (the header's SHA-256 and the exported C API).
- **Minimum OS:** the crate's own objects carry 14.0. Rust's prebuilt standard library keeps Rust's own minimums: `LC_VERSION_MIN_IPHONEOS` or `LC_VERSION_MIN_TVOS` 10.0 on the devices and 14.0 on the simulators, the same as today's prebuilt.
- **Embedded bitcode removed:** Rust's prebuilt standard library objects carry LLVM bitcode for cross-crate LTO, written by a newer LLVM (22) than Xcode 26.6's `nm` and linker read. The build removes the `__LLVM` sections with the toolchain's own `rust-objcopy`; the machine code is unchanged, and `check` requires no `__LLVM` segment.
- **Callers:** `check` records the `dovi_*` functions the libplacebo built here imports (parse, the header and display management queries, and their frees) and those the built FFmpeg imports (the ones its Dolby Vision patch calls), requires each to be exported, and requires libplacebo's to be the six today's libplacebo calls.

### Crash-proof patch

Upstream builds libdovi's C library with `-Cpanic=abort`, so any panic while parsing, converting or writing an RPU ends the app, and several malformed RPUs reach one. Vivid's patch `0001`:

1. builds the library with `-Cpanic=unwind` and runs the body of every exported function (all 21, not only the ten FFmpeg and libplacebo call) inside `catch_unwind`, so no panic reaches or aborts at the C boundary. A caught panic gives the function's normal error result: an `RpuOpaque` carrying an error from the parsers, a null pointer from the getters and writers (the writers also record the error), and −1 from the functions that return a status. A function that was changing the RPU when it panicked drops the RPU, so a half-converted RPU is never written out;
2. checks every count read from the RPU against what the rest of the input could hold before reserving memory for it (a pivot takes the base layer bit depth, a reshaping piece at least two bits, an extension block nine, an EMDF payload byte eight), and caps what is reserved up front at 64 elements. An allocation the system refuses aborts a Rust program whatever its panic setting, so catching panics alone would not be enough;
3. refuses to write a field that holds `u64::MAX`, which an Exp-Golomb code with 64 leading zeros gives a field parsing only stores. The crate's bit writer cannot encode that value and first writes 512 MiB of zero bits; the write failed anyway, and now fails before reserving anything;
4. returns no header when the header says display management data is present but that query could not build it, because libplacebo reads the display management result without checking for null;
5. treats a null buffer as a parse error, and no longer builds a `Vec` from a null pointer when freeing an `RpuOpaqueList` that carries an error.

Every check fires only on input that could not parse or write anyway, so input that did not abort before gives the same results, bytes and structures. Error texts change only where one of these checks fires first; every added text is a single line without any of the fault substrings Vivid's log consumers look for.

### C API test

`lucid.py test-libdovi` (the libdovi C API test job) builds libdovi for the runner from the same pinned source, toolchain and crates, twice: unpatched (with upstream's `-Cpanic=abort`) and with the series. It requires identical headers and exports, then links [`engine/tests/libdovi/harness.c`](../../engine/tests/libdovi/harness.c) against each build and runs the corpus [`libdovi_test.py`](../../engine/tests/libdovi/libdovi_test.py) generates, one process per case, so a case that aborts the unpatched build is recorded rather than ending the run. Each case goes through:

- FFmpeg's profile 7 conversion sequence (parse, error, mode 2, write, frees) and libplacebo's sequence (parse, header, the display management query whenever the header says the data is present, which must then not be null, and the frees);
- every parser, getter and writer, every conversion mode (0 to 4, 5 and 255), the active area and mapping edits, the RPU file parser and, once, every function with null pointers.

The corpus holds about 19,400 cases:

| Group | What | Patched build must |
| --- | --- | --- |
| Valid RPUs | every RPU in libdovi's test assets (profiles 5, 7 FEL and MEL, 8.1 and 8.4, CM v2.9 and v4.0, AV1) plus RPUs written field by field here, each given to the parser for its form | give byte-identical dumps to the unpatched build |
| Abort classes | one changed field with a recomputed CRC: a mapping method code of 2 or more; linear interpolation in a first-order piece; the CRC range class FFmpeg's guard skips; unknown CM v4.0 level 8, 9 and 10 lengths; very large Exp-Golomb counts; curves mixing polynomial and MMR pieces | return error results (the writer class parses as upstream, and only writing fails) |
| Guard vectors | the four vectors of the specification's 9.4, and boundary cases | return error results |
| Zero-filled, truncated, random | zero-filled buffers after every start pattern libdovi recognises; every truncation of profile 5, 7 FEL, 7 MEL and 8.1 RPUs; random bytes from a fixed seed after every start pattern | return error results |
| Bit flips | every single-bit flip of a profile 7 FEL and a MEL RPU | return error results |
| Structured fuzz | valid RPUs with random byte changes and a corrected CRC, so parsing reaches the mapping and display management data | not abort |

Results at `11994e3` (run 38368890048, `macos-26`): 19,381 cases; the patched build never aborted and used at most 2.5 MB per case; the unpatched build aborted on 6,157 cases and on every abort class, and peaked at 1.5 GB in one case. All 1,931 valid asset RPUs and the 9 written ones gave byte-identical dumps from both builds. Where the unpatched build did not abort, results matched apart from 1,716 cases whose error text changed because a count check fired first and 15 whose header query rule 4 turned into null (RPUs without display management data, converted with mode 4, which neither FFmpeg nor libplacebo does). Very large counts abort the unpatched build on the runner only where the allocation is refused: counts up to 2^40 and EMDF sizes up to 2^32 are allocated lazily there and did not abort, while 2^48 and above did, apart from one pivot count of 2^64−2, which wraps to no pivots at all.

The test fails on any abort, crash or hang (20 s per case) of the patched build, on more than 64 MiB of memory for one case, on any unexpected result, and on any difference from the unpatched build wherever that build does not abort, other than error texts the patch's own checks change and headers rule 4 above turns into null. It also requires the unpatched build to abort on every abort class, which shows the corpus reaches each abort site. The summary, with the abort counts per class and group, appears on the workflow run page, and the report is uploaded as `lucid-engine-libdovi-test`.

## Dependencies

The eleven libraries FFmpeg, libass and libmpv depend on are built from upstream source with each project's own build system, at the versions, options, flags, assertions, optimisation and deployment targets of today's binaries, as the [library build facts](lucid-engine-libs-build-facts.md) record them. Each is installed on its own (`<work>/<slice>/deps/<name>`), keeps only its headers, its static library and the pkg-config file consumers use, and its pkg-config file is then made visible to the libraries built after it.

| Library | Build | Options (`engine/config/`) | Deployment target | Assertions |
| --- | --- | --- | --- | --- |
| FreeType 2.12.1 | meson, `release` | `freetype-meson.txt`: brotli, bzip2, HarfBuzz, mmap and PNG off; `zlib=system` | 13.0 | none in the code |
| FriBidi 1.0.12 | meson, `release` | `fribidi-meson.txt`: no binaries, deprecated API, docs or tests | 13.0 | none in the code |
| HarfBuzz 8.1.1 | meson, `release` | `harfbuzz-meson.txt`: today's four options, plus every optional backend (GLib, GObject, cairo, ICU, chafa, introspection, Graphite, CoreText) disabled explicitly instead of left to detection on the build host | 13.0 | on |
| libunibreak 6.1 | upstream's `configure` and make | `unibreak-configure.txt`: static only; `CFLAGS` are the cross flags alone, so it is unoptimised, as today | 13.0 | on |
| Little CMS 2.17 | meson, `release` | `lcms2-meson.txt`: none | 14.0 | on |
| uavs3d 1.2 | CMake `Release`, Makefiles | `uavs3d-cmake.txt`: `COMPILE_10BIT=1`; arm64 NEON assembly; only the library target is built | 15.0 | off |
| libbluray 1.4.0 | meson, `release` | `libbluray-meson.txt`: embedded libudfread, FreeType and libxml2 on, fontconfig, BD-J jar, tools and docs off; patch `0001` | 14.0 | none in the code |
| uchardet 0.0.8 | CMake `Release`, Makefiles | `uchardet-cmake.txt`: no command-line tool | 13.0 | off |
| shaderc 2025.5 | CMake `Release`, Makefiles | `shaderc-cmake.txt`: today's options, plus no executables; consumers get upstream's combined `shaderc_combined.pc` as `shaderc.pc` | 14.0 | off |
| MoltenVK 1.4.1 | MoltenVK's Xcode projects | `moltenvk-make.txt`: `MVK_XCODE_16=0 MVK_XCODE_26=0` | its project's: iOS 14.0, tvOS 14.5 | off |
| libplacebo 7.351.0 | meson, `release` | `libplacebo-meson.txt`: Vulkan, OpenGL, shaderc, Little CMS, Dolby Vision and libdovi on; d3d11, glslang, xxhash, unwind, demos and tests off | 14.0 | on |

- **Flags:** every library except MoltenVK gets exactly the cross flags of the build facts (1.4): `-arch arm64 -isysroot <SDK> -target <triple> <version-min flag>`, plus `-DHAVE_FORK=0` on tvOS, as `CFLAGS`, `CPPFLAGS`, `CXXFLAGS` and `ASMFLAGS` (through the meson cross file for meson projects), and `-lc++` plus the same flags as `LDFLAGS`. The minimum OS is the library's own (column above), as today; clang raises a 13.0 arm64 simulator target to 14.0, as it did today.
- **Assertions:** the meson libraries keep meson's default `b_ndebug=false`, not the `b_ndebug=true` the libass and mpv cross files use, so HarfBuzz, Little CMS and libplacebo keep their assertions as today. The CMake libraries are `Release` builds, which define `NDEBUG`, and MoltenVK's Release configuration defines `NDEBUG=1`, as today.
- **CMake projects** get the common values of facts 1.4: `BUILD_SHARED_LIBS=0`, `CMAKE_BUILD_TYPE=Release`, `CMAKE_INSTALL_PREFIX=/lucid-engine`, `CMAKE_OSX_ARCHITECTURES=arm64`, `CMAKE_OSX_SYSROOT=<sdk>`, `CMAKE_POLICY_VERSION_MINIMUM=3.5`, `CMAKE_SYSTEM_NAME=iOS` or `tvOS`, `CMAKE_SYSTEM_PROCESSOR=arm64` and `CMAKE_VERBOSE_MAKEFILE=0`. They are also pointed at Xcode's Python (`Python_EXECUTABLE`, `Python3_EXECUTABLE`), the one meson runs under, for their code generators, so no other Python on the runner is picked up.
- **libunibreak** is configured from upstream's release tarball, whose `configure` script upstream generated from the tag's tree; today's build generated it on the build host from the tag archive. The library's sources and flags are the same. The tarball's `config.sub` (2018) does not know `arm64`, so `--host` is `aarch64-ios-darwin` or `aarch64-tvos-darwin`, its canonical name for today's `arm64-ios-darwin` and `arm64-tvos-darwin`.
- **HarfBuzz** gets one meson cross-file property from `harfbuzz-cross.txt`, `has_function_sincosf = false`: Xcode 26.6's clang has a `__builtin_sincosf`, which meson's check takes as the function being present, but the SDK declares no `sincosf`, so HarfBuzz would fail to compile. Xcode 15.4's check found none, so this keeps today's code (it calls `sinf` and `cosf`, which clang joins into `__sincosf_stret`).
- **shaderc** is built with glslang, SPIRV-Tools and SPIRV-Headers in `third_party/` at its `DEPS` revisions. Upstream installs its non-combined library as `shaderc.pc`; consumers need the combined library (`-lshaderc_combined`), so the build copies upstream's `shaderc_combined.pc` over it, as today's `shaderc.pc` is.
- **MoltenVK** follows upstream's documented procedure for the slice's platform. The source tree already holds the externals where `fetchDependencies` would put them, so of that script only its remaining steps run, with its own arguments: unpacking SPIRV-Tools' pre-generated headers (`Templates/spirv-tools/build.zip`), building the `ExternalDependencies` scheme for the platform and packaging it with upstream's scripts. Then upstream's Makefile target (`ios`, `iossim`, `tvos` or `tvossim`) builds MoltenVK. The Makefile turns command-line variables into preprocessor definitions; `MVK_XCODE_16=0` and `MVK_XCODE_26=0` keep the SDK-gated code paths compiled out, as they were with today's SDK 17.5. The slice's library is taken from upstream's static `MoltenVK.xcframework` and thinned to arm64, with upstream's `include/` (Vulkan-Headers v1.4.334). MoltenVK produces no `vulkan.pc`, so the build writes today's: `Vulkan-Loader`, version 1.4.334 (read from the headers), `-lMoltenVK` and its frameworks (IOKit on iOS only).
- **uavs3d** writes `version.h` and `uavs3d.pc` into its source folder while configuring, so it is built from a copy; patch `0001` gives `version.h` today's version values.
- **libplacebo** uses the slice's own libdovi, Little CMS, shaderc and MoltenVK through pkg-config (today it was also given libdovi's include and library paths directly, which changes nothing), and the `3rdparty/Vulkan-Headers` submodule (v1.4.310) for its Vulkan code generation, as today. Built from archives without Git, it reports `v7.351.0` as its version.

### Dependency cache

The dependencies take most of a slice's build time (shaderc, MoltenVK and HarfBuzz above all), so CI keeps their builds. `lucid.py build --cache DIR` gives every dependency a key: the SHA-256 of its pins (its source, its parts, the toolchain and the build tools), its patch series, its option files, the code of the functions that build it, and the keys of the libraries it builds against (libplacebo's include libdovi's). A cached build is reused only when its key is equal; any other dependency is built and stored. `lucid.py cache-key --slice <slice>` prints the key of all of a slice's dependencies together.

The workflow restores the cache with `actions/cache` under that key, or failing that the slice's most recent entry (GitHub lets a run restore entries saved on its own ref or on `main`, so a pull request's first run builds every dependency unless `main` has them), and saves it whenever the run built a dependency: under the key once every dependency is in the cache, otherwise under a key of its own that the next run still finds. Each dependency's provenance records whether it was built or reused, its key, and the toolchain that built it. The checks run on reused builds exactly as on new ones.

Timings on the `macos-26` runners (run 38425539055): building all eleven took 10 to 18 minutes per slice (shaderc 3 to 5, MoltenVK 5 to 10, the simulators' longest because MoltenVK also builds their x86_64 code, HarfBuzz about 1), and a slice job 18 to 27 minutes. With every dependency reused, a slice job takes about 10 minutes, as before. A slice's cache entry is about 10 MB.

## libass

libass 0.17.5 is built for every slice with three patches, against the FreeType, FriBidi, HarfBuzz and libunibreak built here (see [Dependencies](#dependencies)). Unpatched upstream draws subtitles with the same pixels as today's engine, but a parity check found it costs more on every frame:

- an unchanged sign with a vector clip, and an unchanged SubRip line drawn with a background box (`BorderStyle` 4), are rebuilt into new image buffers on every frame, and libass compares images by buffer, so it reports a change on every frame and the video output re-renders and re-enqueues the same subtitles;
- for a static event with a character that no font can provide (no font covers it, or the suggested font file cannot be opened), font fallback is searched again on every frame;
- symbol fonts (Webdings, Wingdings) given non-Latin text place their glyphs differently from today's engine.

A review of upstream libass found that upstream commit `057a5334` (patch `0001`) fixes the symbol fonts, and that upstream pull request #951 (patch `0002`), applied to 0.17.5, gives today's change reports, pixels and fonts on large corpora. Both are taken unchanged; neither needed editing to apply.

### Vivid's patch 0010

`0002` caches an event's images under its text, style and margins, so it can keep a render with missing glyphs: another event with the same text later reuses them, and an event keeps them even after a later character of the same render, or another event, has added a font face that covers them. Unpatched libass shows those glyphs from the next frame. Patch `0010` (ISC, like libass) closes these gaps and changes nothing else:

- **Unresolved glyphs stay with their event.** A glyph is unresolved when `ass_font_get_index()` finds none for a printable character, after its fallback search. Output with an unresolved glyph never goes into the shared entry for its key; that entry only records it, and the event keeps its own entry, under an owner id kept in its `ASS_RenderPriv` and the number of fallback faces added to any font when its render started. Another event with the same text renders its own text once, with the fonts as they are then, and never inherits missing glyphs.
- **The event finds its own entry first.** An event that has its own entry looks it up directly, with a cache lookup that never creates an entry (`ass_cache_find()`, added by `0010`), and goes through the shared entry only when its own is missing. The shared entry holds no images, and the cut at the start of each frame drops it whenever the images on screen exceed the budget (more than 32 MiB of static images at once, such as four full-frame drawings and a large line at 2160p), so the event must not depend on it.
- **A frame keeps the entries it used.** Every entry a frame uses gets a reference of its own until the next frame has been rendered, as the frame's images keep theirs. The cut at the start of a frame therefore cannot drop the entry of an event still on screen, even one that draws nothing visible (fully transparent, off screen or clipped to nothing) and so has no image to keep it. Such an event is searched for once per appearance, plus once per added fallback face, however full the cache is, and a static event that draws nothing is not rendered again either; with `0002` alone, or the first version of `0010`, it was rendered and searched again on every frame under that pressure. The references belong to the renderer, not to events: each is released once the next frame has been rendered, or when the renderer is freed, so freeing an event or a track leaves nothing behind.
- **New fallback faces are picked up once.** When any font gains a fallback face, each event holding such an entry is rendered once more: on its next frame, or on the same frame when it is rendered after the face was added. Glyphs the new face covers appear when unpatched libass shows them. That costs at most one extra render, and one extra change report, per added face, and nothing while no faces are being added; an event whose glyphs cannot be resolved is not searched for again on later frames. Output without unresolved glyphs is shared and kept as before, because a new face is appended and glyphs that were found keep their face.
- **Effects are part of the key.** Without the event's Effect field in the key, an event with a Banner or Scroll effect could reuse the static images of an earlier event with the same text and not move.
- **Memory is released on every state change.** `0002` bounds the cache at 32 MiB, evicting the least recently used entries, and empties it when the renderer is reconfigured (frame or storage size, margins, aspect ratio, font scale, hinting, line position, style overrides, and `ass_set_fonts`), and when the renderer is freed. `0010` also empties it whenever the snapshot of settings and track state changes, since entries of an older snapshot can never match again: after the shaper, line spacing or margin use changes, or the track's styles or header change.
- **Image clones keep their type.** `0002` hands out copies of cached images without setting their `type`; `0010` copies it.

### Host tests

`lucid.py test-libass` (the libass host test job) builds FreeType, FriBidi and HarfBuzz for the runner from the slices' own `[source:*]` archives and patch series, with only what libass needs (HarfBuzz is built with `-Dsincosf=__sincosf`, because its configure finds `sincosf` in macOS's libm, which declares it only under that name). It then builds libass for the runner from the pinned 0.17.5 archive five times, with the options in `libass-meson.txt` except `-Dlibunibreak=disabled` (libunibreak is not built for the runner; it only changes where lines wrap):

| Build | Patches |
| --- | --- |
| `upstream` | none |
| `symbol-font` | `0001` |
| `event-cache` | `0001`, `0002` |
| `patched` | the whole series |
| `patched-asan` | the whole series, with AddressSanitizer |

[`engine/tests/libass/harness.c`](../../engine/tests/libass/harness.c) is linked against each build. It renders frames through the public API, with fonts from the macOS system through Core Text or through a font provider of its own, and records for every frame the change value `ass_render_frame()` reports, a hash of the frame composited onto a black canvas with integer blending and cut to the tight bounding box of what is drawn (equal hashes mean frames that look the same), a hash of the image list's sizes, positions, colours and bitmap bytes, the font fallback messages (searches, failed searches and fonts that could not be opened), the time `ass_render_frame()` took, for the builds that have it the size of the event render cache, read through libass's private headers, and for the patched builds the fallback faces added and the glyph lookups that no face could satisfy, read from the counters `0010` adds (every render of an event with unresolved glyphs adds to the second, so it also counts those renders). A frame whose image list hashes like the previous frame's takes that frame's composite hash without blending it again. [`libass_test.py`](../../engine/tests/libass/libass_test.py) writes the scenarios, runs each in its own harness process through every build, and checks:

| Group | Scenarios | The patched build must |
| --- | --- | --- |
| Steady | an opaque box (`BorderStyle` 3) and a background box (`BorderStyle` 4) SubRip line, signs with a vector clip, an inverse vector clip and a rectangle clip, an outlined line with a shadow, a drawing, a plain line, and four of them together; 240 frames each at 1920x1080 and 3840x2160 | report no change after the first render and repeat its images (the second render's, when a fallback face was added at the first). Upstream must report a change on every frame for the background box and the vector clips |
| Dynamic | `\move`, `\fad` and `\fade`, `\t`, karaoke (`\k`, `\kf`, `\ko`, `\K`), animated rectangle and inverse clips, animated box colours (`BorderStyle` 3 and 4), collision shifts, events appearing and leaving, Banner and Scroll effects | report upstream's change value on every frame |
| Mixed | static boxes and clipped signs beside moving, fading and karaoke events, and colliding boxed lines | report a change whenever the frame looks different; its values may be lower than upstream's where upstream rebuilt an unchanged image |
| Pixels | styles, override tags, clips and drawings, 3D transforms, vertical Japanese (`@` font), Arabic and Hebrew, emoji, wrapping styles, recurring lines, the same text with different effects, a code point no font has (through Core Text), layers and collisions, at 1080p and 2160p | draw what upstream draws on every frame |
| Symbol fonts | Webdings, Wingdings, Wingdings 2 and 3, and Symbol, with Latin, Cyrillic, Greek, CJK and Arabic text | draw what the `symbol-font` build draws, so any difference from upstream comes from `0001` |
| Fallback | the harness's own fonts: Thai that cannot be resolved (its suggested font file cannot be opened) and Devanagari whose font also covers Thai; a static line and a boxed sign, a face added later in the same render, by a later and by an earlier event, recurring lines with and without a face added between them, and a font file that appears while a line is shown | draw what upstream draws on every frame, except while a newly appeared font file has not yet been added as a face; search for an unresolved glyph once; report one extra change per added face and none after; render a recurring line's own text |
| Memory | 400 distinct boxed lines at 2160p; resets and settings changes | keep the event render cache between 24 and 40 MiB at its peak (32 MiB budget, plus the entries the current frame holds) with its extra memory over upstream bounded and not growing; empty the cache after `ass_set_fonts` and after changing the frame size, storage size, shaper, line spacing, margin use or a style |
| Pressure | 120 frames at 2160p and 24 frames a second of four static full-frame drawings (alpha `E0`, no border or shadow), alone and with a large static line whose glyphs no font provides: an unassigned code point (U+0378), the same beside a Devanagari letter whose fallback face is added on the first frame, a CJK line whose style's family has a CJK font that cannot be opened (the harness's own fonts) and an emoji line (Core Text). The drawings alone take 33.3 MB, just under the 32 MiB budget, and the line (size 120) takes the images on screen over it, so every frame's cut drops each entry no image holds. Then lines that draw nothing visible, so no image on screen holds their entry: the unassigned code point fully transparent (`\alpha&HFF&`), off screen (`\pos(-3000,-3000)`) and clipped to nothing (`\clip(0,0,0,0)`), and the CJK line fully transparent. An off-screen or clipped line adds nothing to the cache, so three static boxed signs (Arial 90, `BorderStyle` 4) join the drawings and the visible output alone keeps the cache at about 36.6 MB, which is checked too | keep the cache over its budget on every frame; give no fallback messages, no render of the line and no change after frame 2, and search, render the line or report a change on frame 2 only when frame 1 added a fallback face. With the harness's own fonts, upstream must search on every frame. The median time per frame after frame 2 is recorded beside the drawings alone, not checked: shared runners are noisy, and with the harness's fast fonts the unassigned line rendered again on every frame cost only about 0.007 ms more than the drawings alone, so a bound of 0.01 ms would not have caught it, while the counts do |

In every scenario, every build must finish; the AddressSanitizer build must give exactly the patched build's results; a frame that looks different from the previous one must report a change; a frame that reports no change must repeat the previous frame's images; and, where no background box is drawn, every image must have a valid type. Wherever no fallback search failed and apart from the scenario with different effects, the patched build must report the same change values and images as the `event-cache` build, so `0010` changes nothing else. The `event-cache` build must show each gap `0010` closes: it keeps the missing glyph after a face is added, reuses the first line's missing glyph, and does not search again for a recurring line.

Results at `fcb6782` (run 38458337996, `macos-26`, about six minutes), the pipeline release `0.1.0` was built from: 82 scenarios through the five builds, 10,062 frames each (50,310 in all), and 10,862 scenario checks and 4 of 4 test checks, all passed. The first cache-pressure fix of `0010`, which only looked an event's own entry up first, passed its own 77 scenarios at `037ee4e` (run 38446693401: 9,462 frames each, 10,201 scenario checks and 4 test checks), but fails 12 checks of the five scenarios added since. On static output, upstream reported a change on all 239 frames after the first for the background box, both vector clips and the combined scenario, at both sizes, and on none for the other steady scenarios; the patched build reported none. The patched build searched for an unresolved glyph once where upstream searched on all 100 frames, and twice where upstream searched 21 to 40 times in the other fallback scenarios. The `event-cache` build drew something different from upstream (from the `symbol-font` build for symbol fonts) in 13 scenarios: the same text with different effects (33 frames), all five symbol font scenarios (19 frames each: CJK characters whose suggested font could not be opened, which a face added for a later character covers) and seven fallback scenarios; the patched build differed only where a font file appeared, within the allowed window. Patch `0001` changed all 20 frames of the Webdings and Wingdings scenarios and none of Symbol's. The event render cache peaked at 37.3 MB over the long run, the patched build used 11.7 to 13.2 MB more memory than upstream at each checkpoint without growing, and the cache was empty after every reset and settings change, while the `event-cache` build kept entries after the shaper, line spacing, margin use and style changes. Under cache pressure the cache held 34.3 to 34.9 MB with each of the four visible lines (33.3 MB with the drawings alone), every line reached glyphs no font provides (the emoji line included, through Core Text on the runner), and the patched build gave no fallback message, no render of the line and no change after frame 2; only the line whose fallback face was added on frame 1 searched once more on frame 2. Upstream searched on every frame (2, 2, 6 and 26 messages a frame for the unassigned, face-added, emoji and CJK lines). With the drawings and the three boxed signs (36.6 MB on their own), the cache held 36.6 to 38.2 MB with each line that draws nothing visible, and each was searched once, on frame 1 (2 messages for the unassigned code point, 26 for the CJK line), and not rendered again, where the `event-cache` build and upstream searched on every frame. The median time per frame after frame 2 was 0.009 to 0.010 ms for the patched build with the visible lines and about 0.012 ms with the invisible ones, against 0.092 to 0.130 ms for the `event-cache` build with the invisible lines and 0.080 to 2.27 ms for upstream (recorded, not checked).

The test fails on any failed check, crash or AddressSanitizer report. The summary appears on the workflow run page, and the report is uploaded as `lucid-engine-libass-test`. The host FreeType, FriBidi and HarfBuzz come from the `[source:*]` pins, so the results above are the integrated pipeline's own (see [Results](#results)); the first fix's 77 scenarios gave the same counts in the pipeline (run 38453269681 at `535bb95`) as on the libass branch.

## Reproducible builds

- `ZERO_AR_DATE=1` is set for every build, so `ar`, `ranlib` and `libtool` write zero timestamps; Rust and `rust-objcopy` write zero timestamps themselves. `check` requires every member of every archive to carry a zero timestamp.
- `SOURCE_DATE_EPOCH` is `1766344100` (2025-12-21 19:08:20 UTC, mpv v0.41.0's commit), which clang uses for `__DATE__` and `__TIME__`. mpv's build date is therefore fixed, and `check` requires it in `Libmpv`.
- Source trees are extracted fresh into the same runner paths, and build paths are stable on GitHub's runners, so unchanged inputs give unchanged binaries.
- `xcodebuild -create-xcframework` lists the slices in its `Info.plist` in a different order from run to run, so `package` rewrites that file with the slices sorted by identifier.
- The packaging job packages the same slices twice and fails unless the two sets of zips are identical.

Results: runs 38367673194 and 38368890048 built every framework of all four slices byte for byte the same, and packaging the first run's slices again gave exactly the second run's `SHA256SUMS`, so unchanged libraries give identical zips across runs.

For the dependencies built from source:

- Runs 38412603172 and 38425539055 each built all eleven from source on all four slices, on different runners, and gave byte-identical `libMoltenVK.a` and dependency framework binaries on every slice.
- With the dependencies built here, run 38425539055's `Libmpv`, `Libass`, `Libdav1d`, `Libdovi` and seven FFmpeg frameworks are byte for byte the same, on all four slices, as those of run 38400124717, which built them against today's interim binaries. Swapping the eleven dependencies changed nothing in the libraries built against them. Both runs built libass unpatched, before its series was merged, which changes `Libass`. (This needs each dependency installed in its own `deps/<name>` folder, as the interim binaries were staged: libplacebo's `libav_internal.h` puts its header path into an assertion text in FFmpeg's `vf_libplacebo`.)

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
| `freetype-meson.txt`, `fribidi-meson.txt`, `harfbuzz-meson.txt`, `lcms2-meson.txt`, `libplacebo-meson.txt`, `libbluray-meson.txt` | the meson options of those dependencies |
| `unibreak-configure.txt` | libunibreak's `configure` options |
| `shaderc-cmake.txt`, `uavs3d-cmake.txt`, `uchardet-cmake.txt` | the CMake options of those dependencies (the common values are in `lucid.py`) |
| `moltenvk-make.txt` | the command-line variables for MoltenVK's Makefile |
| `expected-libs/<name>.txt` | what today's interim build of each dependency ships, recorded by automated comparison of its xcframework and archives: the framework or library name, the files under `Headers/`, the defined global symbols by visibility (default and hidden in full; weak definitions as a count and the SHA-256 of their sorted names), each slice's imports and each slice's minimum OS; and, where Xcode 26.6 differs, the recorded differences (`[imports-toolchain-added]`, `[imports-toolchain-removed]`, `[weak-default-toolchain]`, `[weak-hidden-toolchain]`) |
| `harfbuzz-cross.txt` | an extra meson cross-file property for HarfBuzz: `has_function_sincosf = false` |
| `expected-libs/<name>.pc` | today's pkg-config file of each dependency (`vulkan-ios.pc` and `vulkan-tvos.pc` for MoltenVK's) |
| `expected-libdovi.txt` | libdovi's header SHA-256, exported C API and the functions libplacebo calls, as the last green run recorded them from today's prebuilt |

Compilers come from the selected Xcode (`/usr/bin/clang`). Every library except MoltenVK gets the same flags: `-arch arm64 -isysroot <SDK> -target <triple> <version-min flag>`, plus `-DHAVE_FORK=0` on tvOS and `-lc++` when linking, with the library's own minimum OS (see [Dependencies](#dependencies)). Meson projects get them through a generated cross file, CMake and autotools projects and FFmpeg through `CFLAGS`, `CPPFLAGS`, `CXXFLAGS`, `ASMFLAGS` and `LDFLAGS`, as today. MoltenVK's Xcode projects use their own settings. Libraries install under the prefix `/lucid-engine` and are staged with `DESTDIR`, so no build-machine path appears in the configuration strings.

### Differences from today's binaries

| Area | Today | This pipeline | Why |
| --- | --- | --- | --- |
| Slices | arm64 plus arm64e (tvOS device) and x86_64 (simulators); also Catalyst, macOS and visionOS | arm64 only, iOS and tvOS | Vivid links only arm64 on iPhone, iPad and Apple TV |
| mpv licence | `-Dgpl=true` | `-Dgpl=false` | Decided: LGPL-2.1-or-later libmpv |
| mpv options | `-Dmoltenvk=enabled -Dvo-avfoundation=enabled` | `-Dvo-avfoundation=enabled` only | `moltenvk` exists only with a third-party mpv patch, and upstream meson rejects it; `vo-avfoundation` comes from Vivid's own patch `0025` |
| mpv features | include `gpl`, `moltenvk` and `vo-avfoundation` | without `gpl` and `moltenvk` | Follows from the two rows above |
| FFmpeg licence | `--enable-gpl --enable-version3` (GPL version 3 or later) | neither (LGPL version 2.1 or later) | Decided |
| FFmpeg TLS | OpenSSL 3.3.5 | Secure Transport, with the patch above | Decided |
| FFmpeg components | as listed in the facts | without the `delogo` filter, the `whip` muxer and the `dtls`, `ffrtmpcrypt`, `rtmpe` and `rtmpte` protocols | GPL-only filter; the others need OpenSSL |
| FFmpeg and libdovi | `-I` and `-L ... -ldovi` for a Dolby Vision patch | the same, from the `dovi.pc` of the libdovi built here, through `CFLAGS` and `LDFLAGS` only | Vivid's Dolby Vision patch (`0011`) calls libdovi; FFmpeg's configure has no libdovi switch, so the configure line is unchanged |
| libass | three performance patches | upstream commit `057a5334`, upstream pull request #951 and Vivid's patch `0010` | Upstream changes and Vivid's own patch instead of third-party ones, for today's change reports, pixels and fonts (see [libass](#libass)) |
| dav1d | third-party prebuilt | built from source, same options | Part of this pipeline |
| libdovi | third-party prebuilt: a Rust nightly of December 2025 with `-Zbuild-std`, `-Cpanic=abort`, cargo-c unpinned, crates not locked | built from source: Rust 1.98.0 stable with its prebuilt standard library, cargo-c 0.10.25, locked and vendored crates, `-Cpanic=unwind` and Vivid's patch | Pinned and reproducible; a malformed RPU no longer ends the app (specification 5.13) |
| libdovi slices | arm64e (tvOS device) and x86_64 (simulators) as well | arm64 only | As for the other libraries |
| libdovi bitcode | as built | `__LLVM` sections removed | Xcode's tools cannot read the newer LLVM bitcode Rust's standard library carries |
| mpv build date | the time of the build | 2025-12-21 19:08:20 UTC (`SOURCE_DATE_EPOCH`) | Reproducible builds |
| Archive member timestamps | the time of the build (meson-built libraries) | zero (`ZERO_AR_DATE=1`) | Reproducible builds |
| VideoToolbox Metal key | unrecorded source edit | patch `0002` | Every source change must be a patch |
| pkg-config search path | dependencies, then the build machine's default path | dependencies and two files describing the SDK's own zlib and libxml2 | Keeps the build machine's libraries out of feature detection |
| FFmpeg version string | `n8.0.1` | `8.0.1` | A release archive has no Git tag; changing it would need a source edit |
| mpv version string | `v0.41.0-dirty` | `v0.41.0` | Built from the release archive |
| Minimum OS | 14.0 for these four libraries; libdovi 10.0 (devices) and 14.0 (arm64 simulators) | 14.0; libdovi's crate objects 14.0, its Rust standard library objects as today | Unchanged |
| The eleven dependencies | third-party prebuilt binaries | built from upstream source here, at the same versions, options, assertions, optimisation and deployment targets | Part of this pipeline; checked against today's in `check` |
| Dependencies' compiler | Xcode 15.4, SDK 17.5 | Xcode 26.6 and its SDKs | The pipeline's toolchain. No dependency archive references the compiler's run-time OS-version check. Floating-point results (libplacebo's and Little CMS's colour maths) can differ in the last bit between compiler versions |
| Dependencies' imports | as today's binaries | the same, except: HarfBuzz and Little CMS also call `wcslen`, uavs3d `strlen`; libbluray calls `free` where it read the `xmlFree` pointer (the SDK's libxml2 headers now define `xmlFree(ptr)` as `free(ptr)`); shaderc and MoltenVK no longer call five to seven `std::string` and `basic_streambuf` functions that the SDK's libc++ headers now inline, and call `std::locale`, `setbuf`, `wcslen` and `wmemchr` instead | Xcode 26.6's compiler and SDK; all are libSystem or libc++ functions the app links anyway. `check` requires exactly these differences (`[imports-toolchain-*]` in `engine/config/expected-libs/`) |
| Dependencies' weak definitions | Xcode 15.4's | Xcode 26.6's: the same for eight libraries; HarfBuzz 967 weak hidden (today 961), shaderc 2,534 weak default and 1,176 weak hidden (today 2,477 and 1,063), libplacebo 34 weak hidden (today 32) | Which inline functions and template instances a compiler emits as weak copies, including libc++'s versioned names, differs between compilers; every other defined symbol is as today's. `check` requires the recorded Xcode 26.6 sets |
| HarfBuzz's `sincosf` check | not found (Xcode 15.4) | forced to not found (`has_function_sincosf = false` in `engine/config/harfbuzz-cross.txt`) | Xcode 26.6's clang has a `__builtin_sincosf`, which meson takes as `sincosf` being present, but the SDK declares none and HarfBuzz would not compile; this keeps today's result and code |
| libunibreak's `--host` | `arm64-ios-darwin`, `arm64-tvos-darwin` | `aarch64-ios-darwin`, `aarch64-tvos-darwin` | The release tarball's `config.sub` (2018) does not know `arm64`; `aarch64` is its canonical name for the same host, and libunibreak's `configure` uses the host only to look for tools |
| MoltenVK's SDK-gated code | compiled out (SDK 17.5) | compiled out (`MVK_XCODE_16=0`, `MVK_XCODE_26=0`) | Unchanged; kept with upstream's own Makefile variables |
| MoltenVK and Apple GPU family 9 | never detected (a source change in today's build) | detected, as upstream does | Not reproduced: no source change is needed to build, and Vivid never creates a Vulkan instance, so it is not reached |
| MoltenVK revision string | the tag's commit, from `git rev-parse` | what upstream's build script gives without Git | Built from an archive; it feeds only the Vulkan pipeline-cache UUID |
| SPIRV-Tools version string in shaderc | `SPIRV-Tools v2025.5 v2025.5-0-g262bdab4` | `SPIRV-Tools v2025.5` and `unknown hash`, dated by `SOURCE_DATE_EPOCH` | Built from an archive; reached only through shaderc, which Vivid's playback does not call |
| libplacebo version string | `v7.351.0 (v7.351.0-dirty)` | `v7.351.0` | Built from an archive, without today's Python 3.14 fix (not needed with Xcode's Python); it appears in mpv's version and log output |
| uavs3d version line | `1.2.1_release` and a third-party build identifier | `1.2.1_release` and uavs3d's own commit for tag 1.2 | Patch `0001`; today's identifier was a third-party build repository's commit |
| HarfBuzz optional headers | `hb-cairo.h`, `hb-gobject.h`, `hb-gobject-enums.h`, `hb-gobject-structs.h`, and `HB_HAS_CAIRO` and `HB_HAS_GOBJECT` in `hb-features.h` | none of them | Today cairo and GObject were found on the build host; `libharfbuzz` itself is unchanged and nothing uses them |
| shaderc's `glslc` | built, not shipped | not built | Not part of the combined library |
| libunibreak's `configure` | generated on the build host from the tag archive | upstream's, from the release tarball | The same sources and flags; no autotools needed |
| Source paths in assertion messages | today's build paths | this pipeline's (`../../src/<library>/...`) | Seen only if an assertion fails |
| Bundle identifiers | the third-party prefix | `com.blurbery.vivid.lucid.<Name>` | Decided (blurbery) |

Kept as today, for parity:

- Framework and module names, `[system]` module maps with the umbrella directory `"."` and `export *`, the same header exclusions, and the same `Headers/` layout, including FFmpeg's internal headers and `config.h`. The dependencies' frameworks and headers match today's interim xcframeworks file for file (apart from HarfBuzz's four optional headers above), and MoltenVK is again a bare static library xcframework (`libMoltenVK.a`, no headers or module).
- Info.plist keys and values apart from the identifier prefix: version `87.88.520` and `MinimumOSVersion` `100.0`.
- The Libavutil module still fails to import, because `hwcontext_amf.h`, `hwcontext_drm.h`, `hwcontext_mediacodec.h` and `hwcontext_oh.h` are not excluded. Vivid reaches `avformat_configuration` by symbol name, which still works.

## Outputs

Each slice job uploads `lucid-engine-slice-<slice>` with:

- `frameworks/<Name>.framework`: static archive, `Headers/`, `Modules/module.modulemap` and `Info.plist`;
- `libraries/MoltenVK/libMoltenVK.a`: MoltenVK's static library;
- `provenance.json` and `provenance.md`, including the dependency and decoder test results;
- `audio-tests.json`: the audio output test vectors' result and the hashes it was checked against;
- `vo-tests.txt`: the video output tests' output (`ios-arm64-simulator` only);
- `logs/`: the build output of each library, plus FFmpeg's `config.log`, meson's logs and the decoder tests' host libdovi and FFmpeg builds.

The libdovi C API test job uploads `lucid-engine-libdovi-test` with its report (`libdovi-test.json` and `.md`), the per-case results of both builds and their logs.

The libass host test job uploads `lucid-engine-libass-test` with its report (`libass-test.json` and `.md`), every build's per-frame results (`frames/<build>/<scenario>.txt`) and the build and harness logs.

The packaging job uploads `lucid-engine-xcframeworks` with:

- `<Name>.xcframework.zip` for each of the 21 frameworks and for MoltenVK, with `<Name>.xcframework/` as the zip's root. Before zipping, the job checks every slice's form: a framework with its module map naming the module and the Info.plist keys and identifier, or, for MoltenVK, a bare `libMoltenVK.a`. The zips are written with fixed timestamps and ordering, so identical frameworks give identical zips, and the job checks this by packaging twice;
- `SHA256SUMS`: the SHA-256 of each zip, which is also its SwiftPM checksum;
- `provenance/`: each slice's report.

## Publishing the package

The workflow publishes nothing. The Swift package [`blurbery/lucid-engine`](https://github.com/blurbery/lucid-engine) serves its builds as release assets, and [`engine/publish_package.py`](../../engine/publish_package.py) prepares each release from one green run, in a clean checkout of that repository:

```sh
python3 engine/publish_package.py --run <run id> --version <version> --package /path/to/lucid-engine \
  [--work /path/to/work] [--downloads /path/to/downloads]
```

It needs the GitHub CLI, signed in, Git with the run's commit fetched, the Xcode command-line tools (`swift`) and Python 3.9 or later. It replaces `LICENSES/` and the package's own files in the checkout, so before writing anything it refuses one with uncommitted or untracked files (ignored files such as `.build/` do not count), including those of an earlier preparation that was not committed. It reads `pins.ini` and `app-link.txt` as the run's commit has them, and it refuses to go on at the first problem:

1. **The run.** It must be a push run of the Lucid Engine build workflow on `experiment/lucid-engine-build` by default (`--branch` names another, for example `--branch main` for a push run on `main`), completed and successful, with all four slice jobs, the libdovi and libass test jobs and the packaging job successful.
2. **The artefact.** It downloads the run's `lucid-engine-xcframeworks` (kept for three days), which must hold exactly the 22 zips, `SHA256SUMS` and the four slices' provenance reports. Each zip's SHA-256 must equal its `SHA256SUMS` line and `swift package compute-checksum`; each zip must have only `<Name>.xcframework/` at its root, pass its CRC checks and have an `Info.plist` naming the four arm64 slices; and each provenance report must come from the run's commit, with every check and decoder test passed.
3. **`Package.swift`.** One library product, `LucidEngine`, whose wrapper target (`Sources/LucidEngine/LucidEngine.swift`, which has no code) links exactly the frameworks and libraries of `app-link.txt`, and one `binaryTarget(name:url:checksum:)` per zip at `https://github.com/blurbery/lucid-engine/releases/download/v<version>/<Name>.xcframework.zip`. The tool checks the manifest with `swift package dump-package` and refuses any other URL in it.
4. **`README.md`, `NOTICE` and `LICENSE`.** The README says how to use the package and gives the release's source commit in `blurbery/vivid`, its run, and every library with its version, upstream commit, upstream source, licence and patch series. `NOTICE` lists every library with its version, upstream commit, source, licence, Vivid's patches and the code it contains from other projects, down to the twelve crates compiled into `Libdovi` and Rust's standard library. `LICENSE` puts the package's own files under LGPL-2.1-or-later (blurbery's choice), followed by that licence's text.
5. **`LICENSES/`.** Written afresh from the pinned upstream archives: 35 files from the source and part archives and Rust's standard library, and one from each of the twelve crates. Each archive is downloaded through `lucid.py`'s download function and checked against its SHA-256 and embedded commit, and each crate against libdovi's `Cargo.lock`.
6. **Release assets.** The 22 zips, `SHA256SUMS` and `provenance-<slice>.json` and `.md` are staged in `.build/release-v<version>/` of the package checkout (Git ignores `.build/`), with the release notes beside them. The tool refuses if any file it wrote or staged holds the machine's home folder, user name or host name, or a `/Users/` path other than a CI runner's, or if a file it wrote holds an e-mail address other than a GitHub noreply one.
7. **The commands.** It prints each asset's SHA-256 and the commands that commit the package, push it and create the release (`gh release create v<version> --target <package commit> ...`).

After publishing, download two assets back with `gh release download` and compare them with `SHA256SUMS`, and resolve the package once from a small consumer, which proves every URL and checksum. Pass `--disable-keychain` (and `--disable-netrc`) to `swift package` there: the release assets are public, and otherwise SwiftPM looks up GitHub credentials in the keychain and waits for its permission.

Release [`0.1.0`](https://github.com/blurbery/lucid-engine/releases/tag/v0.1.0) was published this way from run 38458337996 at `fcb6782`: package commit `53ebeac`, tag `v0.1.0`, 31 assets. `Libmpv` and `MoltenVK` downloaded back matched `SHA256SUMS` and `Package.swift`, and a consumer resolved version 0.1.0 at `53ebeac` and all 22 binary targets with their checksums.

## Provenance and checks

`lucid.py build` records the toolchain (Xcode, SDK, clang, meson, ninja, CMake, pkg-config, make, rustc, cargo, cargo-c, `SOURCE_DATE_EPOCH` and `ZERO_AR_DATE`), libdovi's Rust target, `Cargo.lock` hash, vendored crates and Rust flags, the repository commit, the SHA-256 of `pins.ini`, every source archive and part with its hash and embedded commit, every applied patch with its hash, the pristine and patched tree digests, each dependency's configuration as its build reports it (meson's options, CMake's cache, libunibreak's make variables, MoltenVK's Makefile variables), its cache key, whether it was built or reused and the toolchain that built it, the FFmpeg configure arguments and the mpv meson options. `lucid.py check` then verifies the slice and adds its results:

- **Patched trees:** every library is built from source, in the build order; each source tree is unchanged by the build (for a dependency, as recorded straight after its build), and equals a fresh assembly of the pristine archives with the series applied again.
- **Inputs:** archive and part hashes and commits match `pins.ini`, and the applied patches match the series.
- **Dependencies**, each against what today's interim build ships ([`engine/config/expected-libs/`](../../engine/config/expected-libs)), on every slice:
  - The framework (or, for MoltenVK, bare static library) name, form and minimum OS; the Info.plist and module map; and the files under `Headers/`, apart from HarfBuzz's four optional headers.
  - The defined global symbols: default and hidden visibility exactly as today's, for every library. Every symbol `nm` prints must be of a known kind. Weak definitions (copies of inline functions and template instances, the compiler's choice) are compared by count and SHA-256 of their names: with today's where they match (FreeType, FriBidi, libunibreak, Little CMS, uavs3d, libbluray, uchardet and MoltenVK), and otherwise with the set Xcode 26.6 gives from the same sources and options, recorded in the library's `[weak-*-toolchain]` section (HarfBuzz, shaderc and libplacebo; see the differences below).
  - The imports (symbols the archive needs from outside itself), exactly as today's apart from the few each library's `[imports-toolchain-*]` sections record (below), which also shows that nothing pulls in a library today's build did not (PNG, brotli, GLib, ICU, DiskArbitration, `vfork`, `execl` and so on), and whether assertions are compiled in (`___assert_rtn`).
  - The pkg-config file consumers use, field by field and variable by variable, and that it resolves with all its `Requires` through the slice's pkg-config path.
  - The configuration read back: every meson option as passed, with `buildtype=release`, `optimization=3`, `debug=false`, `b_ndebug=false`, `b_lto=false` and `default_library=static`; every CMake option as passed, with `-O3 -DNDEBUG` release flags; libunibreak's `CFLAGS` with no `-O`; MoltenVK's `MVK_XCODE_16=0 MVK_XCODE_26=0`.
  - Per library: FreeType's `ftoption.h` (system zlib on; PNG, brotli, bzip2 and HarfBuzz off); FriBidi's version, interface version and Unicode version (14.0.0); HarfBuzz's version and no `HB_HAS_*` backend; libunibreak's and Little CMS's versions; glslang 16.0.0 in shaderc; MoltenVK 1.4.1 with Vulkan headers 1.4.334; libplacebo's `PL_HAVE_*` set, API version 351 and version string `v7.351.0`; uavs3d's `version.h`, the version line's strings in the binary, `COMPILE_10BIT=1` and its ten NEON assembly objects; libbluray 1.4.0; uchardet's header.
- **FFmpeg:**
  - The configuration in `config.h` and the string `avformat_configuration()` returns (read from the `Libavformat` object that defines it) both equal the configured arguments.
  - The configuration contains `--enable-securetransport` and none of `--enable-gpl`, `--enable-version3`, `--enable-openssl` or `delogo`.
  - Every library's licence string is `LGPL version 2.1 or later`, and `CONFIG_GPL`, `CONFIG_VERSION3` and `CONFIG_OPENSSL` are 0.
  - The enabled components match `expected-ffmpeg-components.txt` exactly, and so do the filter registry symbols `Libavfilter` defines, which is the form the build facts record. (`scale2ref` appears only as a symbol: `vf_scale.o` defines it, but the configure line has never enabled it.)
- **Symbols:**
  - No framework has OpenSSL symbols, references `_SecIdentityCreate` or defines the `delogo` filter.
  - `Libavformat` defines `_avformat_configuration`.
  - `Libavcodec` references `kCVPixelBufferMetalCompatibilityKey` and neither OpenGL compatibility key.
- **Dolby Vision and decoding:**
  - FFmpeg was built with libdovi's include path and `-ldovi`, recorded in the provenance report.
  - `Libavcodec` references `dovi_parse_unspec62_nalu`, `dovi_convert_rpu_with_mode`, `dovi_write_unspec62_nalu` and both per-frame HDR metadata session properties (`kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` and `kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata`). Pristine FFmpeg references none of them.
  - The patched `hevcdec.c` logs its repeated-RPU and skipped-NAL messages at verbose level.
  - No message added by the decoder patches (FFmpeg `0010` to `0029`, mpv `0040` to `0049`) contains a substring Vivid's adapter records as a fault.
  - `Libmpv` contains mpv patch `0040`'s hardware decoding recovery message.
- **mpv:**
  - The recorded meson options match, with `-Dgpl=false` and no `-Dgpl=true` in the binary.
  - The feature list matches `expected-mpv-features.txt`.
  - The binary contains the text of mpv patch `0001`.
  - The client API version is 2.5, with the four expected headers.
- **libass and dav1d:** the versions are 0.17.5 (`0x01705000`) and API 7.0.0, and both archives contain their arm64 assembly.
- **libdovi:**
  - `rpu_parser.h` is identical to today's prebuilt's (its recorded SHA-256), and the exported `dovi_*` functions are the same 21.
  - It is built with `-Cpanic=unwind` (`panic_unwind` linked, `panic_abort` not), with the pinned rustc, without embedded LLVM bitcode, and `dovi.pc` names `dovi` 3.3.2.
  - The `dovi_*` functions libplacebo and FFmpeg import are all exported, and are recorded in the provenance report; libplacebo's are the six today's libplacebo imports.
- **Reproducibility:** every archive member has a zero timestamp, and `Libmpv`'s build date is the one `SOURCE_DATE_EPOCH` gives.
- **Form:** every framework binary is arm64 only, built for the slice's platform with minimum OS 14.0 (libdovi: the crate's objects 14.0, every member for the slice's platform and no newer than 14.0; the dependencies: their own, above). Info.plist values and module maps match, and the FFmpeg header counts match today's (26, 3, 5, 6, 109, 3 and 3).
- **Linkability:**
  - Symbol closure: every undefined symbol in every archive built here is defined by another archive in the link set, by the compiler runtime, or by a public `.tbd` stub in the SDK. Only `___dso_handle` and the Objective-C selector stubs (`_objc_msgSend$<selector>`), which the linker synthesises, are exempt. Every SDK symbol must come from a framework or library in `app-link.txt`, following re-exports, or from libSystem or libobjc.
  - Test link: a small C program that calls `mpv_create`, `mpv_initialize`, `mpv_terminate_destroy`, `avformat_configuration`, `dovi_parse_unspec62_nalu` and `dovi_rpu_free` links, dead-stripped and without forced whole-archive loading, against the 21 frameworks, `libMoltenVK.a` and `app-link.txt`, at Vivid's own deployment targets (iOS 18.0, tvOS 26.0).
  - `Libmpv` keeps the AVFoundation output's `notification name:` log line, which Vivid's adapter reads.
- **Audio output:**
  - `Libmpv` contains all 25 log formats Vivid reads from the audio output, each with its trailing newline, and the standalone `falling back to PCM` with a NUL straight before it. The check also runs on a copy of `Libmpv` without that NUL and must reject it.
  - The option names `manage-audio-session` and `compressed-anchor-start` (each followed by a NUL) and `compressed-lead`, and Vivid's markers `first start recovery after` and `trace edge %s`. `max-lookahead` (followed by a NUL) is in both tvOS slices and absent from both iOS slices.
  - `Libmpv` references `_AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification` and contains the selectors `setDelaysRateChangeUntilHasSufficientMediaData:` and `setSupportsMultichannelContent:error:`.
  - `lucid.py test-audio` builds [`engine/tests/ao_avfoundation_vectors.c`](../../engine/tests/ao_avfoundation_vectors.c) on the runner against the audio output's C files in the slice's patched mpv tree, with address and undefined-behaviour sanitisers, and runs every vector of the specification's section 9.3 through fakes of mpv, the session, the renderer and `AVPlayer`. It writes `audio-tests.json` with the SHA-256 of each source and of the test file, and `check` fails unless the vectors ran and all passed and those hashes match the slice's tree.
- **Video output:** `Libmpv` defines the `avfoundation` video output and registers it first in `vo.c`, ahead of `gpu-next`; `HAVE_VO_AVFOUNDATION` is 1; the option names `composite-osd`, `pip-composite-osd`, `queue-lead-ms` and `presentation` are present and `osd-max-height` and `osd-video-res` are not; and the binary references the CoreMedia, CoreVideo, AVFoundation, Core Image, Metal and UIKit symbols and selectors the output needs, and carries the `DolbyVisionRPUData` key.
- **Video output tests** (`lucid.py test-vo`, once per run, in the `ios-arm64-simulator` job): the output's modules are compiled from the patched tree for the build host and run against the patch specification's acceptance properties and vectors (sections 4 and 9.4): estimator vectors, servo properties checked by simulation and against an independent reference model, readiness and recovery with a fake renderer, the CoreMedia timebase, frame-space geometry, uploads and colour tags, bit-exact blends and composites, the vectorised kernels against their scalar forms (with timings per 4K frame in the run summary), Picture in Picture composites that blend each image once, restore the decoder's rows only when that buffer is presented again and never leave a redrawn picture without its cue, and several subtitle objects drawn together. The centre (`vo_avfoundation.m`) is built twice, the second time with the tvOS conditionals on, and driven through scripted frames against a fake layers module that logs every call in order. The layers module runs on the build host behind a small UIKit shim, against real display layers. The step fails if any case fails or none runs.

The summary of each slice also appears on the workflow run page.

### Decoder tests

`lucid.py test` runs the decoder tests on the build host, compiled from the slice's patched trees, so the code under test is the code that ships. It first builds two host libraries:

- libdovi, from the slice's own patched libdovi tree, with the same pinned Rust toolchain, cargo-c and vendored crates;
- `libavutil`, `libavcodec` and `libavformat` from the slice's patched FFmpeg tree, out of tree under `decoder-tests/ffmpeg-host`. Only the HEVC decoder and parser, the `hevc_videotoolbox` hwaccel, the raw HEVC demuxer and the file protocol are enabled, everything else (autodetection included) is off, and the build uses AddressSanitizer. Its configure line and extra libraries are recorded in the provenance report.

Every suite compiles against the patched FFmpeg source and the host build's generated headers, never a slice's build folder. The step runs three suites and adds their results to the provenance report:

| Suite | Linked against | Covers |
| --- | --- | --- |
| `vt_dovi_tests_scripted_libdovi` | a scripted stand-in for libdovi's C API | Classification, the 24-byte configuration records and atoms (profiles 5, 8.1, 8.2, 8.4, converted 7, compression 3, masking), colour extensions, the plain HEVC retry rules, the profile 7 NAL filter, RPU selection, the guard vectors, and every outcome of the conversion call sequence with its exact warnings |
| `vt_dovi_tests_libdovi` | Vivid's patched libdovi 3.3.2, built for the build host | The converted profile 7 FEL and MEL RPUs of libdovi's test assets are byte-identical to libdovi's own mode 2 output; native profile 5, 8.1 and 8.4 RPUs are forwarded unchanged; the guard vectors never reach libdovi; and every HEVC RPU of the libdovi corpus (`engine/tests/libdovi`), in the NAL unit form FFmpeg sees, goes through FFmpeg's conversion without aborting: appended exactly as libdovi converts it, or skipped with the stage and stripped warnings, every entry of the six abort classes skipped |
| `vt_glue_tests` | the host FFmpeg libraries, the host libdovi and a fake VideoToolbox, under AddressSanitizer | [`vt_glue_tests.m`](../../engine/tests/ffmpeg/vt_glue_tests.m) defines `VTDecompressionSessionCreate`, `VTDecompressionSessionDecodeFrame`, `VTDecompressionSessionWaitForAsynchronousFrames`, `VTSessionSetProperty` and `VTDecompressionSessionInvalidate`, so the linker binds `libavcodec`'s calls to them while VideoToolbox stays linked for its constants. It decodes [`main10-64x64.hevc`](../../engine/tests/ffmpeg/main10-64x64.hevc) (eight 10-bit 64×64 frames made with x265, command in the test) with RPUs from libdovi's test assets and, for profile 7, a type 63 NAL unit added to every access unit, and the record in the codec context's coded side data. For profiles 5, 7 and 8 (8.1 and 8.4), plain HEVC, a refused profile 8 or 7 session (one ordered plain HEVC retry), a refused profile 5 session (software decoding), a restart and refused session properties, at `thread_count` 1 and 4 with frame threading, it checks the codec type, Enable-hardware key, atoms and colour extensions passed to each session, the session properties (only for a final `dvh1` session), each sample's 4-byte length prefixes, slices before RPUs, no type 63 NAL unit, RPU bytes (libdovi's own conversion for profile 7), the sample size against the block length, that a guard-class RPU still submits its frame, and that every decoded frame's attachments equal what libavutil's unpatched `av_vt_pixbuf_set_attachments` makes of the same buffer. For the patch specification's 13.2 it also defines `CFDataCreate` and `CMVideoFormatDescriptionCreate`, forwarding both to the system's own, so it can fail the creation of the 24-byte Dolby Vision configuration record and see every format description. For profiles 5, 7 and 8.1, at hwaccel initialisation and at a restart forced by an image-less frame, at 1 and 4 threads, each failed start must log FFmpeg `0011`'s "Could not add the Dolby Vision configuration to the decoder specification" once and then pristine FFmpeg's specification error once, both at error level, after the start's own verbose path line; the run must log no other line than those listed for it (pristine FFmpeg's hwaccel set-up error after a failed initialisation; the image-less frame's warning, the restart line and pristine FFmpeg's per-frame errors around a failed restart; hevcdec's line for profile 7's enhancement layer) and none with a fault substring; after the failure there must be no format description, no session and no plain HEVC attempt; a failed initialisation must decode every frame in software, and after a failed restart every later frame must fail with no further start |

Each suite counts its checks, and the step fails on any failed check or when a suite ran none.

### Results

Run 38458337996 (`macos-26`, Xcode 26.6) at `fcb6782`, with the libass cache-pressure fixes, the decoder test of the patch specification's 13.2 and the publish tool, passed every job, and release `0.1.0` was published from it. Every slice reused all eleven dependencies from the cache; the slice jobs took 8 to 10 minutes. Apart from `Libass`, whose patch `0010` changed, its 22 zips are byte for byte those of run 38438440651 at `dee336d`, the first run with every library built here (slice jobs of 21 to 27 minutes then, without a dependency cache).

| Job | Result |
| --- | --- |
| Each of the four slices (`ios-arm64`, `ios-arm64-simulator`, `tvos-arm64`, `tvos-arm64-simulator`) | 683 of 683 checks; 140 audio output vectors, none failed; decoder tests: `vt_dovi_tests_scripted_libdovi` 534 checks, `vt_dovi_tests_libdovi` 199,060 and `vt_glue_tests` 5,937 (2,016 of them in the 12 runs of the 13.2 scenarios), none failed |
| Video output tests (`ios-arm64-simulator`) | 1,920 cases, all passed |
| libdovi C API test | 19,381 cases through the patched and unpatched builds; 14 of 14 checks |
| libass host tests | 82 scenarios through the five builds, 10,062 frames each; 10,862 scenario checks and 4 of 4 test checks |
| Packaging | 22 xcframework zips (the 21 frameworks and MoltenVK), identical when packaged twice |

## Still to do

- The device checks of the patch specification (9.5, with the checks that 12.7 and 13.7 add to it) for Vivid's own engine patches: the audio output (mpv `0010` to `0016`), the video output (mpv `0020` to `0025`) and the decoder work (FFmpeg `0010` to `0012`, mpv `0040`). All are in the series and pass the host tests, and the app links them through release `0.1.0`, but none has been checked on a device yet.
- An end-to-end host test of mpv patch `0040`: a host libmpv needs host builds of libplacebo and libass (with FreeType, FriBidi and HarfBuzz). The pipeline builds all of them from source for iOS and tvOS, and `test-libass` builds libass, FreeType, FriBidi and HarfBuzz for the runner, but a runner build of libplacebo and libmpv is not written yet.
- The libass series on a device: subtitle playback with signs, boxed lines and fallback fonts, checking that the video output stops re-rendering unchanged subtitles.
