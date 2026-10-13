<p align="center"><img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid logo"></p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Lucid Engine build</h1>
<p align="center"><a href="../README.md">Documentation</a> · <a href="player-engine.md">Lucid Engine</a> · <a href="lucid-engine-build-facts.md">Build facts</a> · <a href="../playback/lucid-engine-patch-spec.md">Patch specification</a></p>

---

Vivid's own build pipeline for Lucid Engine's media libraries. It builds libmpv, FFmpeg, libass, dav1d and libdovi from their upstream sources with Vivid's patch series, and checks every result against the recorded configuration of today's binaries. Nothing comes from a third-party build repository: the scripts, pins and patches all live in [`engine/`](../../engine).

> [!IMPORTANT]
> These binaries are interim. The app still links the pinned package described in [Lucid Engine](player-engine.md#builds-and-native-audio-patch), and the pipeline runs only on `experiment/lucid-engine-build` and the engine implementers' `experiment/lucid-engine-*` branches. Upstream mpv has no `avfoundation` video output, so these builds cannot replace today's engine until Vivid's own engine patches land: video output, audio output and Dolby Vision.

## What it builds

| Library | Version | Built from | Licence as built | Patch series |
| --- | --- | --- | --- | --- |
| mpv (libmpv) | v0.41.0 (`41f6a645`) | upstream archive | LGPL-2.1-or-later (`-Dgpl=false`) | [`engine/patches/mpv`](../../engine/patches/mpv/series) |
| FFmpeg | n8.0.1 (`894da5ca`) | upstream archive | LGPL-2.1-or-later | [`engine/patches/ffmpeg`](../../engine/patches/ffmpeg/series) |
| libass | 0.17.5 (`4a05d812`) | upstream archive | ISC | none |
| dav1d | 1.5.3 (`b546257f`) | upstream archive | BSD-2-Clause | none |
| libdovi (the `dolby_vision` crate's C API) | 3.3.2 (`4fd2b223`) | upstream archive, Rust 1.98.0 and cargo-c 0.10.25 | MIT | [`engine/patches/libdovi`](../../engine/patches/libdovi/series) |

Each build produces eleven static frameworks: `Libmpv`, `Libass`, `Libdav1d`, `Libdovi` and the seven FFmpeg frameworks (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample` and `Libswscale`).

The remaining dependencies are not built here yet. They come from pinned release assets, at the versions and checksums today's package uses:

| Dependency | Version | Licence |
| --- | --- | --- |
| FreeType, FriBidi, HarfBuzz, libunibreak | 2.12.1, 1.0.12, 8.1.1, 6.1 | FTL, LGPL-2.1-or-later, MIT, Zlib |
| libplacebo | 7.351.0 | LGPL-2.1-or-later |
| Little CMS (lcms2) | 2.17 | MIT |
| MoltenVK | 1.4.1 | Apache-2.0 |
| shaderc | 2025.5 | Apache-2.0 |
| uavs3d | 1.2 | BSD-3-Clause |
| libbluray | 1.4.0 | LGPL-2.1-or-later |
| uchardet | 0.0.8 | LGPL-2.1-or-later |

OpenSSL (`Libssl`, `Libcrypto`) is gone: FFmpeg uses Apple's Secure Transport for TLS. LuaJIT was only ever linked on macOS and is not needed.

## Running it

The [Lucid Engine build workflow](../../.github/workflows/lucid-engine.yml) runs on every push to `experiment/lucid-engine-build`, or to any branch matching `experiment/lucid-engine-*`, that changes `engine/` or the workflow. Engine implementers work on their own `experiment/lucid-engine-*` branches, so their patches are built and checked the same way. It uses the `macos-26` runner with Xcode 26.6. One job per slice:

1. checks that every fetch is pinned and on the allowlist;
2. restores or downloads the pinned inputs and verifies each SHA-256;
3. builds libdovi, dav1d, libass, FFmpeg and libmpv for the slice;
4. runs the provenance, licence, TLS, libdovi, reproducibility and link checks below;
5. builds and runs the decoder tests from the slice's patched FFmpeg and libdovi trees on the build host;
6. uploads the slice's frameworks, provenance report and logs.

Alongside them, the libdovi C API test job builds libdovi for the runner itself, unpatched and patched, and runs the malformed RPU corpus through both (see [libdovi](#libdovi)). A final job, which waits for every slice and the libdovi test, turns the slices into xcframeworks. Artefacts are kept for three days. Each branch has its own concurrency group, so a newer push cancels only that branch's running build.

The tool is [`engine/lucid.py`](../../engine/lucid.py), which needs Python 3.9 or later, the Xcode command-line tools and pkg-config. Build on CI rather than a personal Mac: a slice takes several minutes of full CPU. The steps are the same anywhere:

```sh
python3 engine/lucid.py check-allowlist
python3 engine/lucid.py fetch --downloads /path/to/downloads
python3 engine/lucid.py build --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py check --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py test --slice tvos-arm64 --work /path/to/work --downloads /path/to/downloads
python3 engine/lucid.py package --input /path/to/work/out --out /path/to/release
python3 engine/lucid.py test-libdovi --work /path/to/libdovi-test --downloads /path/to/downloads
```

The work directory must be outside any Git repository and its path must not contain spaces. FFmpeg's version script would otherwise read the enclosing repository, and pkg-config and FFmpeg's configure split paths on spaces. `test-libdovi` has neither restriction and takes a few minutes of one core; `fetch --only rust:,tool:cargo-c,source:libdovi` fetches just what it needs.

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

- `[source:*]`: the five upstream source archives. `lucid.py fetch` also reads the commit id GitHub embeds in each archive and compares it with the pinned commit. libdovi's entry also pins the SHA-256 of the `Cargo.lock` in the archive's `dolby_vision` folder (`7400fd25…`); fetch checks it, then downloads every crate that lock file lists (83, development dependencies included, because Cargo resolves them all) from static.crates.io and checks each against the lock file's checksum, which is the SHA-256 of the `.crate` file.
- `[tool:*]`: meson 1.4.2, ninja 1.12.1 and cargo-c 0.10.25 (the macOS release binary; it embeds cargo 0.99.0, Rust 1.98's). pkg-config comes from the runner image.
- `[rust:*]`: Rust 1.98.0 stable from static.rust-lang.org: `rustc`, `cargo` and the standard library for the runner (`aarch64-apple-darwin`) and for each slice (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-tvos`, `aarch64-apple-tvos-sim`). The hashes are the `xz_hash` values of that release's channel manifest. `lucid.py` unpacks the components itself, without rustup.
- `[prebuilt:*]`: the interim release assets. `url` is the build input (headers, thin static libraries and pkg-config files for every slice). `xcframework_url` is the matching SwiftPM binary, for a package to use until the library is built here.
- `[reference:libdovi]`: today's prebuilt libdovi 3.3.2. It is downloaded only so `check` can require the same header and the same exported C API from the libdovi built here, and is never staged or linked.
- `[toolchain]`: the Xcode version CI must use, the minimum OS (14.0) for every slice, Vivid's own deployment targets (iOS 18.0, tvOS 26.0) for the test link, and `source_date_epoch` (below).

Every download goes through `lucid.py`'s single download function, from these projects and hosts only: FFmpeg, mpv-player, libass, videolan, mesonbuild and ninja-build on GitHub; mpvkit release assets for the interim binaries; quietvoid (libdovi's `dovi_tool`) and lu-zero (cargo-c) on GitHub; `static.rust-lang.org/dist/`; and `static.crates.io/crates/`. The libdovi build itself runs offline: Cargo uses the verified crates as a vendored directory source with `--frozen`, so it resolves and downloads nothing.

`lucid.py check-allowlist` fails the run if any file in `engine/` or the workflow mentions a blocked project, if a URL points at a host that is not allowlisted, if a download is not one of the allowlisted upstream projects, if anything fetches outside `lucid.py`'s single download function, or if a workflow action is not pinned by commit SHA.

## Patch series

Each library has `engine/patches/<library>/series`, listing its patches in order with each file's SHA-256. The build applies them to the pristine source with `patch -p1 -F0` (no fuzz) and refuses any patch whose hash differs. There are no in-place source edits: every change to a source tree is a patch in a series.

| Library | Patch | What it does |
| --- | --- | --- |
| FFmpeg | `0001-securetransport-without-private-identity-api.patch` | Compiles the client-certificate path, which needs the private `SecIdentityCreate`, out of Secure Transport on iOS and tvOS. Server certificates are still checked against the system trust store. |
| FFmpeg | `0002-videotoolbox-request-metal-compatible-pixel-buffers.patch` | Asks VideoToolbox for Metal-compatible pixel buffers instead of the OpenGL ES or OpenGL compatibility flags, matching today's binaries. LGPL-2.1-or-later. |
| mpv | `0001-ad_spdif-recreate-spdif-muxer-on-reset.patch` | Upstream mpv commit `1388a453`, unchanged, with its upstream attribution: recreates the S/PDIF muxer after a seek and waits for a TrueHD major sync. |
| mpv | `0002-ao_avfoundation-build-for-ios-and-tvos.patch` | Lets upstream's AVFoundation audio output (`-Davfoundation=enabled`) compile for iOS and tvOS by keeping the macOS-only CoreAudio device code out of those builds, and builds the CoreFoundation string helpers it calls (`osdep/utils-mac.c`), which upstream builds only with the macOS `cocoa` feature. The output's `notification name:` log line is unchanged. macOS builds with `cocoa` are unchanged. LGPL-2.1-or-later. |
| libdovi | `0001-capi-return-an-error-instead-of-aborting-on-any-input.patch` | Makes every C API function return its normal error result instead of aborting the process, for any input (see [libdovi](#libdovi)). Valid input gives the same results. MIT, like libdovi. |
| FFmpeg | `0010-videotoolbox-give-every-sample-an-explicit-size.patch` | Creates every sample handed to VideoToolbox with an explicit sample size, for every codec. VideoToolbox's Dolby Vision HEVC decoder fails samples without one. LGPL-2.1-or-later. |
| FFmpeg | `0011-videotoolbox-decode-dolby-vision-profiles-5-7-and-8-natively.patch` | Decodes HEVC with a usable Dolby Vision record of profile 5, 7 or 8 through VideoToolbox's Dolby Vision HEVC (`dvh1`) decoder. Profile 7 is presented as profile 8.1: rewritten record, RPUs converted by libdovi 3.3.2 (mode 2), no enhancement layer, and empty or truncated RPUs skipped before libdovi sees them. Profile 7 and 8 retry once as plain HEVC when VideoToolbox refuses the session. Adds the per-frame HDR metadata session properties, keeps VideoToolbox's frame attachments for Dolby Vision sessions and fills missing HDR tags. The logic lives in its own file, `libavcodec/videotoolbox_dovi.c`. LGPL-2.1-or-later. |
| FFmpeg | `0012-hevcdec-log-repeated-dolby-vision-rpus-and-skipped-nal-units-at-verbose.patch` | Logs `Multiple Dolby Vision RPUs found in one AU. Skipping previous.` and `Skipping NAL unit %d` at verbose level instead of warning and info. LGPL-2.1-or-later. |
| mpv | `0040-vd_lavc-tolerate-a-short-burst-of-hardware-decoding-errors.patch` | Once hardware decoding has output a frame, a run of decoding errors ends it only after two keyframes fail to recover it or after 240 errors, instead of at the first error with `hwdec-software-fallback=yes`. Probing still falls back at once. LGPL-2.1-or-later. |

Vivid's own patches for the AVFoundation video and audio outputs, Dolby Vision and the other kept behaviour are written from the [patch specification](../playback/lucid-engine-patch-spec.md), in these number ranges: audio output mpv 0010 to 0019, video output mpv 0020 to 0039, decoder work mpv 0040 to 0049 and FFmpeg 0010 to 0029.

To add a patch, write it against the pristine source (or the previous patch in the series), add its SHA-256 and file name to the end of the `series` file, and push. The build fails if the files a series changes differ from the files its patches name.

## libdovi

libdovi is the C API of the `dolby_vision` crate (Rust, MIT). Two callers in the engine hand it Dolby Vision RPUs taken straight from the media: libplacebo, which mpv calls for every frame that carries an RPU, and FFmpeg's profile 7 conversion once Vivid's Dolby Vision patch lands. The [patch specification](../playback/lucid-engine-patch-spec.md) (5.13) sets the requirements.

### Built from source

- **Source and pins:** tag `libdovi-3.3.2` of `quietvoid/dovi_tool` (commit `4fd2b223`, archive SHA-256 `8ccb1922…`), its locked crates, Rust 1.98.0 and cargo-c 0.10.25, all pinned as above. Rust 1.98.0 ships a standard library for every slice's target, tvOS included, so no nightly and no `-Zbuild-std` is needed.
- **Build:** `cargo cinstall --release --frozen --library-type=staticlib --target <triple>` in the crate folder, with `IPHONEOS_DEPLOYMENT_TARGET` or `TVOS_DEPLOYMENT_TARGET` set to 14.0 and `--remap-path-prefix` keeping build paths out of panic locations. It is built first, so FFmpeg's and mpv's configure steps find its `dovi.pc` where libplacebo's pkg-config file requires it.
- **Form:** framework `Libdovi`, module `Libdovi`, with `Headers/rpu_parser.h`, as today. The header, the pkg-config name `dovi` and the 21 exported `dovi_*` functions are unchanged; `check` compares them with today's prebuilt for every slice.
- **Minimum OS:** the crate's own objects carry 14.0. Rust's prebuilt standard library keeps Rust's own minimums: `LC_VERSION_MIN_IPHONEOS` or `LC_VERSION_MIN_TVOS` 10.0 on the devices and 14.0 on the simulators, the same as today's prebuilt.
- **Embedded bitcode removed:** Rust's prebuilt standard library objects carry LLVM bitcode for cross-crate LTO, written by a newer LLVM (22) than Xcode 26.6's `nm` and linker read. The build removes the `__LLVM` sections with the toolchain's own `rust-objcopy`; the machine code is unchanged, and `check` requires no `__LLVM` segment.
- **Callers:** `check` records the `dovi_*` functions the pinned libplacebo archive imports (parse, the header and display management queries, and their frees) and those the built FFmpeg imports (none until the Dolby Vision patch), and requires each to be exported.

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

The test fails on any abort, crash or hang (20 s per case) of the patched build, on more than 64 MiB of memory for one case, on any unexpected result, and on any difference from the unpatched build wherever that build does not abort, other than error texts the patch's own checks change and headers rule 4 above turns into null. It also requires the unpatched build to abort on every abort class, which shows the corpus reaches each abort site. The summary, with the abort counts per class and group, appears on the workflow run page, and the report is uploaded as `lucid-engine-libdovi-test`.

## Reproducible builds

- `ZERO_AR_DATE=1` is set for every build, so `ar`, `ranlib` and `libtool` write zero timestamps; Rust and `rust-objcopy` write zero timestamps themselves. `check` requires every member of every archive to carry a zero timestamp.
- `SOURCE_DATE_EPOCH` is `1766344100` (2025-12-21 19:08:20 UTC, mpv v0.41.0's commit), which clang uses for `__DATE__` and `__TIME__`. mpv's build date is therefore fixed, and `check` requires it in `Libmpv`.
- Source trees are extracted fresh into the same runner paths, and build paths are stable on GitHub's runners, so unchanged inputs give unchanged binaries.
- `xcodebuild -create-xcframework` lists the slices in its `Info.plist` in a different order from run to run, so `package` rewrites that file with the slices sorted by identifier.
- The packaging job packages the same slices twice and fails unless the two sets of zips are identical.

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
| FFmpeg and libdovi | `-I` and `-L ... -ldovi` for a Dolby Vision patch | the same, from the `dovi.pc` of the libdovi built here, through `CFLAGS` and `LDFLAGS` only | Vivid's Dolby Vision patch (`0011`) calls libdovi; FFmpeg's configure has no libdovi switch, so the configure line is unchanged |
| libass | three performance patches | upstream, unpatched | Decided |
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

Kept as today, for parity:

- Framework and module names, `[system]` module maps with the umbrella directory `"."` and `export *`, the same header exclusions, and the same `Headers/` layout, including FFmpeg's internal headers and `config.h`.
- Info.plist keys and values: `com.mpvkit.<Name>` bundle identifiers, version `87.88.520` and `MinimumOSVersion` `100.0`. Whether to change the identifiers is still open (facts section 6, item 5).
- The Libavutil module still fails to import, because `hwcontext_amf.h`, `hwcontext_drm.h`, `hwcontext_mediacodec.h` and `hwcontext_oh.h` are not excluded. Vivid reaches `avformat_configuration` by symbol name, which still works.

## Outputs

Each slice job uploads `lucid-engine-slice-<slice>` with:

- `frameworks/<Name>.framework`: static archive, `Headers/`, `Modules/module.modulemap` and `Info.plist`;
- `provenance.json` and `provenance.md`;
- `logs/`: the build output of each library, plus FFmpeg's `config.log` and meson's logs.

The libdovi C API test job uploads `lucid-engine-libdovi-test` with its report (`libdovi-test.json` and `.md`), the per-case results of both builds and their logs.

The packaging job uploads `lucid-engine-xcframeworks` with:

- `<Name>.xcframework.zip` for each of the eleven frameworks, with `<Name>.xcframework/` as the zip's root. The zips are written with fixed timestamps and ordering, so identical frameworks give identical zips, and the job checks this by packaging twice;
- `SHA256SUMS`: the SHA-256 of each zip, which is also its SwiftPM checksum;
- `provenance/`: each slice's report.

## Provenance and checks

`lucid.py build` records the toolchain (Xcode, SDK, clang, meson, ninja, pkg-config, make, rustc, cargo, cargo-c, `SOURCE_DATE_EPOCH` and `ZERO_AR_DATE`), libdovi's Rust target, `Cargo.lock` hash, vendored crates and Rust flags, the repository commit, the SHA-256 of `pins.ini`, every source archive with its hash and embedded commit, every applied patch with its hash, the pristine and patched tree digests, the FFmpeg configure arguments and the mpv meson options. `lucid.py check` then verifies the slice and adds its results:

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
  - `rpu_parser.h` is identical to today's prebuilt's, and the exported `dovi_*` functions are the same 21 as the prebuilt's for the slice.
  - It is built with `-Cpanic=unwind` (`panic_unwind` linked, `panic_abort` not), with the pinned rustc, without embedded LLVM bitcode, and `dovi.pc` names `dovi` 3.3.2.
  - The `dovi_*` functions libplacebo and FFmpeg import are all exported, and are recorded in the provenance report.
- **Reproducibility:** every archive member has a zero timestamp, and `Libmpv`'s build date is the one `SOURCE_DATE_EPOCH` gives.
- **Form:** every framework binary is arm64 only, built for the slice's platform with minimum OS 14.0 (libdovi: the crate's objects 14.0, every member for the slice's platform and no newer than 14.0). Info.plist values and module maps match, and the FFmpeg header counts match today's (26, 3, 5, 6, 109, 3 and 3).
- **Linkability:**
  - Symbol closure: every undefined symbol in every built and pinned archive is defined by another archive in the link set, by the compiler runtime, or by a public `.tbd` stub in the SDK. Only `___dso_handle` and the Objective-C selector stubs (`_objc_msgSend$<selector>`), which the linker synthesises, are exempt. Every SDK symbol must come from a framework or library in `app-link.txt`, following re-exports, or from libSystem or libobjc.
  - Test link: a small C program that calls `mpv_create`, `mpv_initialize`, `mpv_terminate_destroy`, `avformat_configuration`, `dovi_parse_unspec62_nalu` and `dovi_rpu_free` links, dead-stripped and without forced whole-archive loading, against the eleven new frameworks, the eleven pinned prebuilt archives and `app-link.txt`, at Vivid's own deployment targets (iOS 18.0, tvOS 26.0).
  - `Libmpv` keeps the AVFoundation output's `notification name:` log line, which Vivid's adapter reads.

The summary of each slice also appears on the workflow run page.

### Decoder tests

`lucid.py test` builds [`engine/tests/ffmpeg/vt_dovi_tests.c`](../../engine/tests/ffmpeg/vt_dovi_tests.c) on the build host together with `libavcodec/videotoolbox_dovi.c` from the slice's patched FFmpeg tree, so the code under test is the code that ships. For the second suite it first builds libdovi for the build host from the slice's own patched libdovi tree, with the same pinned Rust toolchain, cargo-c and vendored crates. It runs two suites and adds their results to the provenance report:

| Suite | Linked against | Covers |
| --- | --- | --- |
| `vt_dovi_tests_scripted_libdovi` | a scripted stand-in for libdovi's C API | Classification, the 24-byte configuration records and atoms (profiles 5, 8.1, 8.2, 8.4, converted 7, compression 3, masking), colour extensions, the plain HEVC retry rules, the profile 7 NAL filter, RPU selection, the guard vectors, every outcome of the conversion call sequence with its exact warnings, and the frame attachments on real CoreVideo buffers |
| `vt_dovi_tests_libdovi` | Vivid's patched libdovi 3.3.2, built for the build host | The converted profile 7 FEL and MEL RPUs of libdovi's test assets are byte-identical to libdovi's own mode 2 output; native profile 5, 8.1 and 8.4 RPUs are forwarded unchanged; the guard vectors never reach libdovi; and every RPU of the libdovi corpus (`engine/tests/libdovi`) in its HEVC NAL form goes through FFmpeg's conversion without aborting: appended exactly as libdovi converts it, or skipped with the stage and stripped warnings, every entry of the six abort classes skipped |

Each suite counts its checks, and the step fails on any failed check or when a suite ran none.

## Still to do

- Vivid's own engine patches: an `avfoundation` video output and the native audio output changes Vivid relies on today. Until they exist, these builds cannot be linked into a shipping app. The Dolby Vision decoder patches are in the series but have not yet been checked on a device.
- Building the remaining dependencies from source, starting with the ones that carry the most code (libplacebo, shaderc and MoltenVK).
- Passing libdovi's include path and `-ldovi` to FFmpeg again, together with Vivid's Dolby Vision patch, and checking `Libavcodec`'s `dovi_*` imports (specification 8.4 and 8.6).
- A Swift package that serves these xcframeworks, updating `use-patched-libmpv.sh` for the new slice identifiers, and deciding the bundle identifiers.
- Licence files and notices for the LGPL FFmpeg and libmpv and the removal of OpenSSL (`THIRD_PARTY_NOTICES.md` and the in-app licences) once the app links these builds.
