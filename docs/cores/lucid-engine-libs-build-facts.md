# Lucid Engine interim libraries: facts for building them from upstream source

Facts for the eleven libraries that Vivid's pipeline (`engine/pins.ini`, `[prebuilt:*]`) took as interim prebuilt binaries until 14 October 2026: FreeType, FriBidi, HarfBuzz, libunibreak, libplacebo, Little CMS (lcms2), MoltenVK, shaderc, uavs3d, libbluray and uchardet. It records versions, upstream source URLs with SHA-256 hashes, option values, flags, features, pkg-config contracts, binary observations and the observable effect of every source modification in today's binaries.

Prepared 13 October 2026. It extends [`lucid-engine-build-facts.md`](lucid-engine-build-facts.md), sections 2.4 to 2.13, and corrects it where section 8 says so.

> [!NOTE]
> **Status, 14 October 2026:** all eleven libraries are now built from these upstream sources by Vivid's own pipeline (`experiment/lucid-engine-libs`), and the interim assets of 1.2 are no longer downloaded. How each is built, and what still differs from today's binaries, is in [Lucid Engine build](lucid-engine-build.md#dependencies). Release `0.1.0` of `blurbery/lucid-engine` serves those builds, and the app pins it. The facts below are unchanged: they describe the interim binaries ("today's binaries" below), which `lucid.py check` compares the new builds with.

## 0. Evidence and conventions

| Tag | Meaning |
| --- | --- |
| [bin] | Observed in today's binaries: the interim prebuilt archives (`-all.zip`) and xcframework zips listed in 1.2, inspected with `lipo`, `ar`, `otool`, `nm` and `strings`, or in the Vivid 0.14.3 (75) iOS archive. |
| [cfg] | A configuration value (option, flag, URL, toolchain) used for the build that produced the asset. |
| [up] | Taken from upstream source at the stated tag or commit. |
| [dl] | Downloaded on 13 October 2026 and hashed. Sizes are in bytes. |
| [ci] | GitHub release or Actions metadata. |
| [vivid] | Vivid repository (`origin/main`, or the branch named). |

- Slice names used here are the pipeline's: `ios-arm64`, `ios-arm64-simulator`, `tvos-arm64`, `tvos-arm64-simulator`. Today's xcframework slices are `ios-arm64`, `ios-arm64_x86_64-simulator`, `tvos-arm64_arm64e` and `tvos-arm64_x86_64-simulator`. Every [bin] fact below is for the arm64 member of the matching slice.
- "Exported" means a defined global symbol (`nm -gU`). "Default" and "hidden" are its visibility: hidden symbols are private externs, visible to the static linker but not exported from a final image.
- "Asserts on" means the archive references `___assert_rtn` (C `assert` compiled in, `NDEBUG` not defined).
- Build-machine paths are written `<work>`.

---

## Summary answers

### A. Are today's shipped binaries the same builds as the interim pins?

Yes. Same versions, same options and same modifications. Nothing in today's shipped engine differs from the `[prebuilt:*]` pins.

- Today's app links the engine through a Swift package pinned in `iosApp/project-ios.yml`, `iosApp/project.yml` and `Package.resolved` on `origin/main` [vivid]. For these eleven libraries, that package's binary targets are the interim xcframework zips, with SwiftPM checksums equal to `pins.ini`'s `xcframework_sha256` values [cfg]. All eleven zips were downloaded, and each SHA-256 equals both [dl].
- For every library and all four Vivid slices, the arm64 static archive that the pipeline stages from the interim archive is byte-identical to the arm64 member of the matching xcframework slice. MoltenVK's interim archive carries the xcframework itself, and it is identical to the MoltenVK xcframework zip [bin]. The interim archive hashes equal `pins.ini`'s `sha256` values [dl].
- Today's shipped Libmpv and FFmpeg were built from that package against the headers and `.pc` files of these same interim archives, at exactly these URLs [cfg]. The reference binaries come from Vivid's engine CI runs 38330109119 (tvOS) and 38342351081 (iOS), both `-Dgpl=false`.
  - The Vivid 0.14.3 (75) iOS archive's Libmpv reports `-Dgpl=true` [bin], so the iOS reference is not that archive's Libmpv.
  - This does not change the answer for the eleven libraries: every Libmpv and FFmpeg build from that package compiles against, and links, the same eleven builds.
- Every asset was last updated before the reference runs: the latest is uavs3d on 25 July 2026, and Vivid runs 38330109119 and 38342351081 started on 13 October 2026 [ci].
- The Vivid 0.14.3 (75) iOS executable contains code from all eleven. Its strings include MoltenVK, shaderc and glslang, libplacebo, Little CMS, libbluray, uchardet, uavs3d, FreeType and HarfBuzz markers [bin].

### B. Which libraries are reachable in Vivid's playback

Vivid plays with `vo=avfoundation`, `hwdec=videotoolbox` on devices (`no` in simulators), and sets no `gpu-api`, `gpu-context`, `vf`, `af` or `lavfi-complex` (`lucid-engine-patch-spec.md` 1.7). The complete option table there lists neither `icc-profile` nor `sub-codepage`. `vo_avfoundation` draws libass's subtitle images on a separate subtitle layer (`lucid-engine-patch-spec.md` section 4). LucidSubtitleInventory's helper instance uses `vo=null` [vivid]. Reachability was derived from symbol references in today's Libmpv and FFmpeg and from these settings. No runtime tracing was done.

| Library | Linked into the app | Reached during playback |
| --- | --- | --- |
| FreeType, FriBidi, HarfBuzz, libunibreak | yes | Yes. libass renders every text and ASS subtitle (mpv `sd_ass`) and the OSD (`osd_libass`) with them. FreeType's libbluray use (TextST) is not reached. |
| libplacebo | yes | Yes, but only its CPU-side colour utilities: colour-space and colour-representation names, equality, merging, HDR checks, rescaling and nominal luminance in `mp_image`, `csputils`, the decoder wrapper, `sd_ass`, `vf_format` and property reporting. It also calls `pl_hdr_metadata_from_dovi_rpu`, which calls libdovi, for every frame that carries a Dolby Vision RPU. Its renderer, Vulkan and OpenGL backends, shader generation and ICC handling are not reached. |
| lcms2 | yes | No. Its callers are mpv's `video/out/gpu/lcms.c` (vo_gpu and vo_gpu_next only), libplacebo's ICC path (renderer only) and FFmpeg's `decode.c`, `encode.c` and `fflcms2.c`. FFmpeg's path runs only when `AV_CODEC_FLAG2_ICC_PROFILES` is set, and neither upstream mpv 0.41.0, the Apple-patched tree nor Vivid's mpv patches set it. |
| MoltenVK | yes | No Vulkan instance is ever created, because no Vulkan context or `hwdec=vulkan` is used. Its static initialisers do run at app launch: the archive has 36 initialiser entries, 35 of them C++ global constructors from MoltenVK sources. |
| shaderc | yes | Its compile entry points are not reached. Only libplacebo's Vulkan GLSL compiler and FFmpeg's Vulkan filters (`vulkan_shaderc.c` in libavcodec and libavfilter) call them. Four glslang static initialisers (`Scan.cpp`, `ShaderLang.cpp`, `doc.cpp`, `hlslScanContext.cpp`) run at launch. The iOS app's `__init_offsets` section has 40 entries, which matches 36 plus 4. The app is stripped, so this attribution is by count only. |
| uavs3d | yes | Only for AVS3 video. FFmpeg's `libuavs3d` decoder, `avs3` demuxer and `avs3` parser are enabled, and VideoToolbox does not decode AVS3, so such streams decode in software through uavs3d. |
| libbluray | yes | No. mpv reaches it only through the `bd://`, `br://` and `bluray://` protocols or a local BDMV directory. Vivid opens network URLs and its own managed-stream protocol. FFmpeg is not built with libbluray. |
| uchardet | yes | Only when mpv must guess the encoding of text subtitle data that has no byte-order mark and is not valid UTF-8, with `sub-codepage` at its default `auto`. Vivid does not set `sub-codepage`. |

### C. Exported symbols of today's binaries (ios-arm64)

The per-library symbol lists are kept as separate data files, which the coordinator hands over on request:

- `<lib>.ios-arm64.exported.txt`: one line per defined global symbol, `default` or `hidden`, a tab, then the symbol name, sorted by name.
- `<lib>.ios-arm64.imports.txt`: the symbols the archive needs from outside itself (undefined in some member and defined in none).
- `MANIFEST.tsv`: for each library, the source xcframework zip and its SHA-256, the SHA-256 and size of the arm64 archive taken from the slice, and the counts.
- `slice-hashes.tsv`: the SHA-256 and size of the arm64 archive in all four Vivid slices of every library.

`<lib>` is one of `freetype`, `fribidi`, `harfbuzz`, `unibreak`, `libplacebo`, `lcms2`, `moltenvk`, `shaderc`, `uavs3d`, `libbluray` and `uchardet`.

| Library | Exported (default / hidden) | Imports |
| --- | --- | --- |
| FreeType | 656 (216 / 440) | 37 |
| FriBidi | 56 (36 / 20) | 11 |
| HarfBuzz | 1611 (481 / 1130) | 57 |
| libunibreak | 30 (30 / 0) | 7 |
| libplacebo | 862 (504 / 358) | 130 |
| lcms2 | 462 (376 / 86) | 55 |
| MoltenVK | 565 (565 / 0), of which 431 are `vk*` | 495 |
| shaderc (combined) | 7440 (6322 / 1118) | 219 |
| uavs3d | 266 (266 / 0) | 28 |
| libbluray | 380 (76 / 304) | 84 |
| uchardet | 351 (331 / 20) | 10 |

### D. What would make a from-source build differ observably, and how to avoid it

Each item gives today's fact and the way to keep it. Details are in section 3.

1. **Versions.** Shaping, bidi, line breaking, charset detection and colour tables come from each library's own code and Unicode data. Today's versions are FreeType 2.12.1, FriBidi 1.0.12 (Unicode 14.0.0), HarfBuzz 8.1.1, libunibreak 6.1, uchardet 0.0.8 and libplacebo 7.351.0. Newer releases, for example FreeType 2.14.1, FriBidi 1.0.16 and HarfBuzz 12.3.2, would change subtitle rendering. Keep the exact versions in section 3.
2. **FreeType features.** PNG is off, so colour bitmap glyphs (sbix and CBDT, as in Apple Color Emoji) do not render in subtitles. Brotli is off, so WOFF2 fonts, including WOFF2 fonts attached to a file, do not load. bzip2 is off. FreeType's HarfBuzz integration is off, which affects only the auto-hinter's glyph coverage. mmap is off. zlib is on, through the system zlib (`FT_CONFIG_OPTION_USE_ZLIB` and `FT_CONFIG_OPTION_SYSTEM_ZLIB`).
   - Keep every one of these values. Enabling PNG or brotli visibly changes subtitle output.
   - The option value used today, `zlib=enabled`, is FreeType's alias for `auto`. `auto` takes the system zlib only when meson's `zlib` dependency is found; otherwise it builds FreeType's bundled zlib subproject (a wrap download), a different binary.
   - FreeType's value `system` gives the same `ftoption.h` as today and fails instead of falling back. `png=disabled` must stay explicit, because `png=auto` has a libpng subproject fallback.
3. **HarfBuzz host detection.** Today `glib` is disabled. `gobject` and `cairo` were left at `auto` and were found on the macOS build host through its default pkg-config path. `icu` was left at `auto` and not found.
   - Only `hb-features.h` (`HB_HAS_CAIRO 1`, `HB_HAS_GOBJECT 1`), extra headers and unshipped side libraries reflect gobject and cairo. `libharfbuzz.a` contains no cairo, GObject, GLib, ICU, CoreText or FreeType code, and uses HarfBuzz's built-in Unicode data (`hb-ucd`).
   - If a from-source build found GLib or ICU, HarfBuzz's default Unicode functions would change. Disable `glib`, `icu`, `gobject`, `cairo`, `chafa`, `introspection`, `graphite`, `graphite2`, `coretext` and `freetype` explicitly.
   - The only remaining difference is then `HB_HAS_CAIRO` and `HB_HAS_GOBJECT` undefined in `hb-features.h` and no `hb-cairo.h` or `hb-gobject*.h` headers. No consumer uses them.
4. **Assertions.**
   - HarfBuzz, libplacebo, lcms2 and libunibreak are built with assertions on. A failed assertion aborts the process. Keep `NDEBUG` undefined for them: meson `b_ndebug` stays `false` (its default) for HarfBuzz, libplacebo and lcms2. The pipeline's mpv and libass convention, `b_ndebug=true`, must not be carried over.
   - FreeType, FriBidi and libbluray reference no `assert`.
   - shaderc, uavs3d and uchardet are CMake `Release` builds, which define `NDEBUG`. MoltenVK's Release configuration defines `NDEBUG=1`. Keep both.
5. **Optimisation.** The output is the same either way; only timing differs. For strict parity:
   - libunibreak is unoptimised today: `CFLAGS` was set explicitly to the cross flags of 1.4, which carry no `-O`, so autoconf's default `-g -O2` was not applied. Compile it without an `-O` flag.
   - The meson libraries use buildtype `release` (`-O3`, no debug info).
   - The CMake libraries use `Release` (`-O3 -DNDEBUG`).
   - MoltenVK uses `-O2` from its own project.
6. **Compiler and SDK.** All eleven were compiled by Xcode 15.4 with SDK 17.5 (every object records SDK 17.5). The pipeline uses Xcode 26.6.
   - No archive references the compiler's run-time OS-version check (`__isPlatformVersionAtLeast`), so for the ten C and C++ libraries other than MoltenVK the SDK only changes declarations seen at compile time.
   - Floating-point results (libplacebo's and lcms2's colour maths) can differ in the last bit between compiler versions. Exact bit parity is not guaranteed; keep the same optimisation level and the compiler's default floating-point contraction.
7. **MoltenVK SDK gates.** This is the largest build-dependent difference, but it has no effect in Vivid unless Vulkan is used. See 3.7.
   - MoltenVK compiles whole feature paths only when the SDK is new enough: `MVK_XCODE_16` (iOS or tvOS SDK 18 or later, for example residency sets and Metal math-mode options) and `MVK_XCODE_26` (SDK 26 or later, for example Metal 4 and GPU family Apple10). Today both are off (SDK 17.5). Built with Xcode 26.6, both would be on.
   - Upstream defines both macros only when they are not already defined. Whether MoltenVK 1.4.1 compiles against SDK 26 with both predefined as 0 was not tested (section 7). Building with SDK 17.5 reproduces today's state.
   - Separately, today's binary never detects Apple GPU family 9 (3.7). Matching that needs a source change that keeps the family-9 flag false.
8. **libplacebo.** Keep these:
   - `PL_HAVE_LIBDOVI 1` and `PL_HAVE_DOVI 1`. Without them `pl_hdr_metadata_from_dovi_rpu` does nothing, and Dolby Vision frames lose the HDR metadata mpv derives from their RPUs. This path is reached in playback.
   - Vulkan code generation from the `3rdparty/Vulkan-Headers` submodule at `v1.4.310` (`registry/vk.xml`), not from MoltenVK's headers. This affects only the Vulkan backend.
   - Today's embedded version string `v7.351.0 (v7.351.0-dirty)`, returned by `pl_version()` and printed in mpv's version and log output. An archive build without git metadata embeds `v7.351.0`. Either reproduce the string or accept the log difference.
   - Assertion messages also embed relative source paths of the form `../../../../libplacebo-v7.351.0/src/...`. They appear only if an assertion fails.
9. **uavs3d.**
   - `COMPILE_10BIT=1`, confirmed in the binary (bit depth 10). With upstream's default of 0, 10-bit AVS3 streams do not decode.
   - The arm64 NEON assembly is selected by `CMAKE_SYSTEM_PROCESSOR=arm64`.
   - Every `uavs3d_create` call prints one line to standard output, of the form `libuavs3d(10): 1.2.1_release, <40-hex commit id>`. The same version, `1.2.1`, is the `.pc` version.
   - Both values come from git metadata at build time (item 13). Today the build directory sat inside a third-party build repository's checkout that had a single commit, so the commit count was 1 and the commit id is that repository's, not uavs3d's. Today's binary therefore embeds a third-party build identifier in that line; Vivid's build embeds uavs3d's own commit for tag 1.2 there instead.
   - To keep the printed version and the `.pc` version as today, the generated `version.h` must hold `VER_BUILD 1`, `VERSION_STR "1.2.1"` and `VERSION_TYPE "release"`. In Vivid's build, `VERSION_SHA1` holds `0e20d2c291853f196c68922a264bcd8471d75b68`, the tag's commit, fixed by uavs3d patch `0001` and checked by `lucid.py check`.
   - FFmpeg requires `uavs3d >= 1.1.41`.
10. **pkg-config contract.** Consumers resolve these names and versions: `freetype2` 24.3.18, `fribidi` 1.0.12, `harfbuzz` 8.1.1, `libunibreak` 6.1, `libplacebo` 7.351.0, `lcms2` 2.17, `vulkan` 1.4.334, `shaderc` (the combined library, version string 2023.8.1), `uavs3d` 1.2.1, `libbluray` 1.4.0, `uchardet` 0.0.8 and `dovi` (libdovi, source-built).
    - `vulkan.pc` is not produced by MoltenVK upstream; section 3.7 gives its content.
    - FFmpeg enables its Vulkan 1.4 code only when `vulkan >= 1.4.317`, so keep `vulkan.pc` at 1.4.334 with the v1.4.334 headers, or FFmpeg's compiled Vulkan feature set changes.
    - `shaderc.pc` must describe `-lshaderc_combined`.
    - Today `freetype2.pc`'s `Requires: zlib` and `libbluray.pc`'s `Requires: libxml-2.0 >= 2.6` resolve through `.pc` files on the build host. Without a resolvable `zlib.pc` and `libxml-2.0.pc`, `pkg-config freetype2` (and so libass, FFmpeg and libbluray configuration) fails.
    - The pipeline already writes SDK-based `zlib.pc` and `libxml-2.0.pc` for each slice (`engine/lucid.py`) [vivid]. Keep them visible when FreeType is built: FreeType then finds zlib through pkg-config and writes the same `Requires: zlib` line.
11. **Deployment targets.** Today's minimum OS differs per library (1.3). The pipeline's single `minimum_os = 14.0` changes the recorded `minos` for FreeType, FriBidi, HarfBuzz, libunibreak and uchardet (13.0 today on device), uavs3d (15.0 today) and MoltenVK on tvOS (14.5 today, from MoltenVK's own project). None of the archives references the compiler's run-time OS-version check (item 6). MoltenVK makes its own run-time OS-version checks through `mvkOSVersion`, so its behaviour follows the OS it runs on, not its deployment target. MoltenVK's own deployment targets come from its project unless overridden.
12. **libbluray libxml2.** Today's libxml2 compile flags came from a pkg-config file on the build host, inferred to describe the macOS SDK's libxml2. Linking was against the target SDK's libxml2. A from-source build should give libbluray the target SDK's `libxml-2.0` entry, which the pipeline already writes.
13. **Strings derived from git at build time.** Five values are computed by upstream build steps that run `git` in the source tree or, for uavs3d, in the build directory. Built from an archive without git metadata, each changes. Built inside another repository's work tree (for example a CI checkout of Vivid), each describes that repository instead.
    - libplacebo: `pl_version()` returns `v7.351.0 (v7.351.0-dirty)` from `git describe --dirty`. Without git it is `v7.351.0`. It appears in mpv's version and log output.
    - MoltenVK: the full commit `db445ff2042d9ce348c439ad8451112f354b8d2a`, from `git rev-parse HEAD`, written to its generated revision header. Its first 8 characters feed MoltenVK's pipeline-cache UUID, which is Vulkan-only.
    - shaderc (combined library): SPIRV-Tools' version strings `v2025.5` and `SPIRV-Tools v2025.5 v2025.5-0-g262bdab4`. Without git the second ends in `unknown hash, <date>`, with the date taken from `SOURCE_DATE_EPOCH` when set. Upstream SPIRV-Tools takes the description from the environment variable `FORCED_BUILD_VERSION_DESCRIPTION` when it is set. glslang's `16.0.0` comes from its change log, not git.
    - uavs3d: the version line and `.pc` version of item 9. Today's line carries a third-party build identifier; Vivid's carries uavs3d's own tag commit, `0e20d2c2…` (item 9).
    - FreeType, FriBidi, HarfBuzz, libunibreak, lcms2, libbluray and uchardet embed no git-derived strings.

---

## 1. Common facts

### 1.1 Producer and toolchain [ci] [bin]

- All eleven were built on GitHub-hosted `macos-14` runners with Xcode 15.4 and meson 1.4.2, plus Homebrew's `autoconf`, `automake`, `cmake`, `libtool`, `nasm`, `ninja` and `pkg-config`.
- Every object's `LC_BUILD_VERSION` records SDK 17.5, except the ten uavs3d assembly objects, which record no SDK version.
- Form: static `ar` archives, one per library. No bitcode (`__LLVM` segment absent), no debug information (`__debug_info` absent) and no LTO (all members are Mach-O objects). Every library except uchardet references the stack protector (`___stack_chk_guard`, clang's default).
- The exact clang version is not recorded in the objects (no debug info); it is inferred from SDK 17.5 and the CI's Xcode selection.

### 1.2 Today's interim assets (the inputs being replaced) [cfg] [dl]

Each row's archive was the `url` of its `[prebuilt:*]` section in `engine/pins.ini` (SHA-256 = that section's `sha256`), and the xcframework zip its `xcframework_url` (SHA-256 = `xcframework_sha256`); both sections are gone now. The four text libraries come from one interim release.

| Library | Interim archive (pipeline input), SHA-256 | Xcframework zip (linked by today's package), SHA-256 |
| --- | --- | --- |
| FreeType | `libfreetype-all.zip` `f0eec59e51f4137ba57afa849393ba4815c25418870b9511990bd4ebeacdbfaf` | `Libfreetype.xcframework.zip` `f2840aba1ce35e51c0595557eee82c908dac8e32108ecc0661301c06061e051c` |
| FriBidi | `libfribidi-all.zip` `e20ccc160ea2995f2ef2c5ee0ec50f307cbc10c371fb299b5df62546de07d59d` | `Libfribidi.xcframework.zip` `4a55513792ef7a17893875f74cc84c56f3657e8768c07a7a96f563a11dc4b743` |
| HarfBuzz | `libharfbuzz-all.zip` `c1f56b4f47b64b15e0be16a93703a6db484079878de16b6d598d22055d86f24c` | `Libharfbuzz.xcframework.zip` `91558d8497d9d97bc11eeef8b744d104315893bfee8f17483d8002e14565f84b` |
| libunibreak | `libunibreak-all.zip` `06f7e68102bb9f9f963b2517455dc543f438f7beccd002edcd63dcd1cbccd9a5` | `Libunibreak.xcframework.zip` `001087c0e927ae00f604422b539898b81eb77230ea7700597b70393cd51e946c` |
| libplacebo | `libplacebo-all.zip` `aa8574c1160deb17863a82258d9a4289e5a5413ca3a58f5e3b12bd25e5585919` | `Libplacebo.xcframework.zip` `3b2bd57b82549566963effadf0891a141448d9f89c7d48fca0b8f823b854bac6` |
| lcms2 | `lcms2-all.zip` `8c118b2c04e2440ecf25ffebfa7952ebb09aba83a71378e3b9ed45dae3a6115a` | `lcms2.xcframework.zip` `dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982` |
| MoltenVK | `MoltenVK-all.zip` `9f65e1025f49c55394da475e40fbe1da8dbd10382d730ce81ebc4c5ac40104d1` | `MoltenVK.xcframework.zip` `9bd1ca1e4563bacd25d6e55d37b10341d50b2601bc2684bc332188e79daa2b79` |
| shaderc | `libshaderc-all.zip` `1079da73a292e5b2cea6a02fa2208c4935ead79a98043f81708424510e0ab53f` | `Libshaderc_combined.xcframework.zip` `758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b` |
| uavs3d | `libuavs3d-all.zip` `8644c7a8182679dbe762b522356606220bb6d2196a5ec65511eda42ef48b3e7a` | `Libuavs3d.xcframework.zip` `bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789` |
| libbluray | `libbluray-all.zip` `c0302f43258ba41d9661dea0be4a7c9c1dd59d30d284ecfbf7319157c8e8a8de` | `Libbluray.xcframework.zip` `bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d` |
| uchardet | `libuchardet-all.zip` `2e530b2d5448a1ca9d1f0a6b3ddf80729a870a6ec6c0f8555bc89c58143f01d1` | `Libuchardet.xcframework.zip` `503202caa0dafb6996b2443f53408a713b49f6c2d4a26d7856fd6143513a50d7` |

### 1.3 Deployment targets per library [bin] [cfg]

| Library | Device (iOS and tvOS) | Simulator arm64 (iOS and tvOS) |
| --- | --- | --- |
| FreeType, FriBidi, HarfBuzz, libunibreak, uchardet | 13.0 | 14.0 (the flags request 13.0; clang raises arm64 simulator targets to 14.0) |
| libplacebo, lcms2, shaderc, libbluray | 14.0 | 14.0 |
| MoltenVK | iOS 14.0, tvOS 14.5 | iOS 14.0, tvOS 14.5 |
| uavs3d | 15.0 | 15.0 |

### 1.4 Compiler and linker flags [cfg]

For every library except MoltenVK, per slice:

| Slice | `-target` | Version-min flag | SDK | meson `subsystem` | CMake `CMAKE_SYSTEM_NAME` | autotools `--host` |
| --- | --- | --- | --- | --- | --- | --- |
| ios-arm64 | `arm64-apple-ios<MIN>` | `-mios-version-min=<MIN>` | `iphoneos` | `ios` | `iOS` | `arm64-ios-darwin` |
| ios-arm64-simulator | `arm64-apple-ios<MIN>-simulator` | `-mios-simulator-version-min=<MIN>` | `iphonesimulator` | `ios-simulator` | `iOS` | `arm64-ios-darwin` |
| tvos-arm64 | `arm64-apple-tvos<MIN>` | `-mtvos-version-min=<MIN>` | `appletvos` | `tvos` | `tvOS` | `arm64-tvos-darwin` |
| tvos-arm64-simulator | `arm64-apple-tvos<MIN>-simulator` | `-mtvos-simulator-version-min=<MIN>` | `appletvsimulator` | `tvos-simulator` | `tvOS` | `arm64-tvos-darwin` |

- Compilers: `/usr/bin/clang` for C and `/usr/bin/clang++` for C++ (the `CC` and `CXX` values).
- `CFLAGS`, `CPPFLAGS` and `CXXFLAGS` (and `ASMFLAGS` for lcms2, libplacebo, shaderc, libbluray and uavs3d) are exactly `-arch arm64 -isysroot <SDK path> -target <triple> <version-min flag>`, plus `-DHAVE_FORK=0` on both tvOS slices. There is no `-O`, `-g`, `-fvisibility`, `-flto`, `-fembed-bitcode` or `-ffunction-sections`.
- `LDFLAGS` = `-lc++ -arch arm64 -isysroot <SDK path> -target <triple> <version-min flag>`.
- `PKG_CONFIG_LIBDIR` = the `lib/pkgconfig` directories of already-built dependencies for the same slice, followed by the build host's default pkg-config search path [cfg].
  - That host path resolved `zlib` for FreeType, `libxml-2.0` for libbluray, and `cairo` and `gobject-2.0` for HarfBuzz [bin].
  - That these were Homebrew's `.pc` files describing the macOS SDK's zlib and libxml2 and Homebrew's cairo and GLib is inferred, not observed (section 7).
- libplacebo additionally gets `-I<libdovi>/include` in its C flags and `-L<libdovi>/lib -ldovi` in `LDFLAGS`.

Meson builds (FreeType, FriBidi, HarfBuzz, libplacebo, lcms2, libbluray) use a cross file with these values:

| Meson setting | Value |
| --- | --- |
| Host machine | system `darwin`; subsystem per the slice table; kernel `xnu`; CPU family `aarch64`; CPU `arm64`; endian `little` |
| Compilers | C and Objective-C `/usr/bin/clang`; C++ and Objective-C++ `/usr/bin/clang++` |
| Other tools | `ar` and `strip` are the target SDK's own tools (as `xcrun` locates them for that SDK); `pkg-config` is the host's |
| Built-in options | `buildtype=release`, `default_library=static`, `prefix=<work>` |
| Compile and link arguments | the compile arguments of all four languages (C, C++, Objective-C, Objective-C++) are the C flags above; their link arguments are `LDFLAGS` |
| Properties | two `has_function_*` overrides, the same two as in the example iPhone and tvOS cross files in meson's own repository (`printf` forced present, and an unused function name forced absent). No meson build here checks either function, so they have no effect and need not be reproduced. |

- Left at meson defaults: `b_lto=false`, `b_ndebug=false` (asserts on), `b_staticpic=true`, `debug=false` (from `release`), `optimization=3` (from `release`).

CMake builds (shaderc, uavs3d, uchardet):
- `BUILD_SHARED_LIBS=0`, `CMAKE_BUILD_TYPE=Release`, `CMAKE_INSTALL_PREFIX=<work>`, `CMAKE_OSX_ARCHITECTURES=arm64`, `CMAKE_OSX_SYSROOT=<sdk>` (the lower-case SDK names in the table), `CMAKE_POLICY_VERSION_MINIMUM=3.5`, `CMAKE_SYSTEM_NAME=<iOS|tvOS>`, `CMAKE_SYSTEM_PROCESSOR=arm64`, `CMAKE_VERBOSE_MAKEFILE=0`.
- CMake's default Makefile generator, built and installed with `make`.

Autotools build (libunibreak):
- `configure` with `--prefix=<work>` plus the options in 3.4, and the environment above. Built and installed with `make`.

MoltenVK uses none of the above (3.7).

### 1.5 Source modifications, all eleven [cfg]

The build configurations behind today's binaries change library source only here:
- libplacebo: one change (3.5)
- MoltenVK: one change (3.7)
- shaderc: edits to two SPIRV-Tools tool sources (3.8)
- uavs3d: one change (3.9)
- libbluray: two changes (3.10)

FreeType, FriBidi, HarfBuzz, libunibreak, lcms2 and uchardet are unmodified. Everything else in today's assets differs from a plain upstream install only in packaging: installed `.pc` prefix paths, file names (the shaderc `.pc` files, 3.8), bundle metadata and package manifests.

### 1.6 Observed optimisation, assertions and visibility [bin]

| Library | Build | Optimisation | Asserts | Objects |
| --- | --- | --- | --- | --- |
| FreeType | meson release | optimised | none referenced | 41 |
| FriBidi | meson release | optimised | none referenced | 18 |
| HarfBuzz | meson release | optimised | on | 53 |
| libunibreak | autotools | unoptimised (every local stored to and reloaded from the stack, no inlining of small static functions) | on | 9 |
| libplacebo | meson release (overrides the project default `debugoptimized`; no debug info) | optimised | on | 56 |
| lcms2 | meson release | optimised | on | 26 |
| MoltenVK | Xcode Release | `-O2` (project) | off (`NDEBUG=1`) | 1 prelinked master object |
| shaderc | CMake Release | optimised | off | 250 |
| uavs3d | CMake Release | optimised | off | 29 (19 C, 10 assembly) |
| libbluray | meson release | optimised | none referenced | 59 |
| uchardet | CMake Release | optimised | off | 50 |

---

## 2. Dependency graph

Build-time prerequisites (headers, static library and `.pc` for the same slice):

| Library | Needs, from these eleven or the source-built set | From the SDK |
| --- | --- | --- |
| FreeType | none | zlib |
| FriBidi, HarfBuzz, libunibreak, lcms2, shaderc, uavs3d, uchardet | none | none (HarfBuzz, lcms2 and uavs3d use pthread; shaderc and uchardet use libc++) |
| MoltenVK | none (its own externals, 3.7) | Metal, QuartzCore, IOSurface, CoreGraphics, CoreFoundation, Foundation, UIKit, libdispatch, libc++ (the generated `vulkan.pc` also lists IOKit on iOS) |
| libplacebo | shaderc, MoltenVK (`vulkan.pc` and headers), lcms2, libdovi (source-built) | none (uses `dlopen` and `dlsym`) |
| libbluray | FreeType | libxml2, CoreFoundation |
| libass (source-built) | FreeType, FriBidi, HarfBuzz, libunibreak | iconv, CoreText |
| FFmpeg (source-built) | FreeType, FriBidi, HarfBuzz, libass, lcms2, libplacebo, MoltenVK (headers and `vulkan.pc` only, no link-time references), shaderc, uavs3d, dav1d; libdovi only with the Dolby Vision patch | libxml2, zlib |
| mpv (source-built) | FFmpeg, libass, libplacebo, lcms2, libbluray, uchardet, `vulkan` | zlib, iconv |

Consumers' version requirements [up]:
- libass: `freetype2 >= 9.17.3`, `fribidi >= 0.19.7`, `harfbuzz >= 1.2.3`, `libunibreak >= 1.1`.
- FFmpeg n8.0.1: `lcms2 >= 2.13`, `libplacebo >= 5.229.0` (with `pl_vulkan_create`), `shaderc >= 2019.1`, `uavs3d >= 1.1.41`, `vulkan >= 1.3.277` (1.4 code when `>= 1.4.317`), `freetype2`, `fribidi`, `harfbuzz`.
- mpv 0.41.0: `libplacebo >= 6.338.2`, `lcms2 >= 2.6`, `libbluray >= 0.5.0`, `uchardet`, `vulkan >= 1.3.238`.
- libplacebo: `shaderc >= 2019.1`, `vulkan`, `lcms2 >= 2.9`, `dovi >= 1.6.7`.

Link-time references in today's binaries [bin]:
- Libmpv to libplacebo, lcms2 (only `video/out/gpu/lcms.c`), MoltenVK (5 `vk*` symbols), uchardet (`misc/charset_conv.c`), libbluray (`stream/stream_bluray.c`) and libass.
- Libavcodec to lcms2 (`decode`, `encode`, `fflcms2`), shaderc (`vulkan_shaderc`), uavs3d (`libuavs3d`) and libdovi (`videotoolbox`).
- Libavfilter to shaderc (`vulkan_shaderc`), libplacebo (`vf_libplacebo`) and libass (`vf_subtitles`).
- libplacebo to shaderc, lcms2, libdovi and MoltenVK (`vkGetInstanceProcAddr`).
- libbluray to FreeType (9 symbols) and libxml2 (8 symbols).

---

## 3. Library by library

### 3.1 FreeType 2.12.1

- Upstream: the FreeType project, `https://gitlab.freedesktop.org/freetype/freetype`, with an official read-only mirror at `https://github.com/freetype/freetype`. Tag `VER-2-12-1`, annotated tag object `4cc0dd694aacb6f452608ac290e20332938d17ec`, commit `e8ebfe988b5f57bfb9a3ecb13c70d9791bce9ecf` [up]. Licence FTL (or GPL-2.0), used under FTL.
- Source [dl]:
  - Tag archive (the exact tree today's build used): `https://github.com/freetype/freetype/archive/refs/tags/VER-2-12-1.tar.gz`, SHA-256 `0e72cae32751598d126cfd4bceda909f646b7231ab8c52e28abb686c20a2bea1`, 2,484,027, embedded commit `e8ebfe98`.
  - Release tarball: `https://download.savannah.gnu.org/releases/freetype/freetype-2.12.1.tar.xz`, SHA-256 `4766f20157cc4cf0cd292f80bf917f92d1c439b243ac3018debf6b9140c41a7f`, 2,471,916.
  - No file present in both differs. The tarball adds generated autotools files, `ChangeLog`, `docs/reference` and the `dlg` sources. The tag archive adds git and CI files, `docs/markdown` and `subprojects/` (the `dlg` submodule pointer and zlib and libpng wraps).
  - The tag's `dlg` submodule (`subprojects/dlg` at `d142e646e263c89f93663e027c2f0d03739ab42d`, `https://github.com/nyorain/dlg`) was present in today's tree. FreeType 2.12.1's meson build does not use it.
- Build system: meson. Options [cfg]:
  - `brotli=disabled`, `bzip2=disabled`, `harfbuzz=disabled`, `mmap=disabled`, `png=disabled`.
  - `zlib=enabled` (alias of `auto`). It resolved to system zlib through pkg-config, giving `FT_CONFIG_OPTION_USE_ZLIB` and `FT_CONFIG_OPTION_SYSTEM_ZLIB`.
  - `tests` left at its default, `disabled`.
- Resulting configuration [bin] [up]:
  - The installed `freetype/config/ftoption.h` differs from upstream's default only in `FT_CONFIG_OPTION_SYSTEM_ZLIB` being defined. All other options are upstream defaults.
  - The installed `ftconfig.h` is upstream's default `include/freetype/config/ftconfig.h`. With mmap disabled, the ANSI stdio `ftsystem.c` is used, not the Unix mmap one.
  - Upstream's meson file builds the library with hidden default visibility (`FT_EXPORT` symbols are default).
- Modules compiled: truetype, type1, cff, cid, pfr, type42, winfonts, pcf, bdf, sfnt, autofit, pshinter, smooth, raster, svg, sdf (`ft_sdf_renderer_class` and `ft_bitmap_sdf_renderer_class`), psaux, psnames, cache, gzip, lzw. Base extensions: bbox, bdf, bitmap, cid, fstype, gasp, glyph, gxval, mm, otval, patent, pfr, stroke, synth, type1, winfnt. No bzip2 module. The installed `ftmodule.h` lists one renderer entry as `None_renderer_class`, a quirk of 2.12.1's meson module-list generation; the compiled objects reference the two sdf renderer classes.
- Installed headers: 54 under `freetype2/`. Every one is identical to upstream except the generated `ftoption.h` (above) and `ftmodule.h`.
- Imports: zlib (`inflate`, `inflateInit2_`, `inflateEnd`, `inflateReset`), libc. No PNG, bzip2, brotli or HarfBuzz symbols.
- pkg-config `freetype2.pc`:
  - `Name: FreeType 2`, `Version: 24.3.18`, `Requires: zlib`
  - `Libs: -L${libdir} -lfreetype`, `Cflags: -I${includedir}/freetype2`
- Source modifications: none.
- Official upstream Apple binary: none.

### 3.2 FriBidi 1.0.12

- Upstream `https://github.com/fribidi/fribidi`, tag `v1.0.12`, commit `6428d8469e536bcbb6e12c7b79ba6659371c435a` [up]. Licence LGPL-2.1-or-later.
- Source [dl]:
  - Tag archive (exact tree used today): `https://github.com/fribidi/fribidi/archive/refs/tags/v1.0.12.tar.gz`, SHA-256 `2e9e859876571f03567ac91e5ed3b5308791f31cda083408c2b60fa1fe00a39d`, 2,110,289, embedded commit `6428d846`.
  - Release tarball: `https://github.com/fribidi/fribidi/releases/download/v1.0.12/fribidi-1.0.12.tar.xz`, SHA-256 `0cd233f97fc8c67bb3ac27ce8440def5d3ffacf516765b91c2cc654498293495`, 1,154,912.
  - No file present in both differs. The tarball adds autotools output. The tag archive adds CI files, `HISTORY`, `USERS`, `bin/fribidi-fuzzer.c`, `gen.tab/gen-arabic-liga.sh`, `git.mk` and `test/fuzzing`.
- Build system: meson. Options [cfg]: `bin=false`, `deprecated=false`, `docs=false`, `tests=false`; `fuzzer_ldflags` default.
- Result [bin]:
  - `fribidi-config.h`: `FRIBIDI_VERSION "1.0.12"`, `FRIBIDI_INTERFACE_VERSION 4`, `FRIBIDI_SIZEOF_INT 4`.
  - `fribidi-unicode-version.h`: `FRIBIDI_UNICODE_VERSION "14.0.0"`.
  - The other 20 installed headers are identical to upstream.
  - No deprecated API is compiled.
- pkg-config `fribidi.pc`:
  - `Name: GNU FriBidi`, `Version: 1.0.12`, no `Requires`
  - `Libs: -L${libdir} -lfribidi`, `Cflags: -I${includedir}/fribidi`
- Source modifications: none.
- Official upstream Apple binary: none. The GitHub release has only the source tarball.

### 3.3 HarfBuzz 8.1.1

- Upstream `https://github.com/harfbuzz/harfbuzz`, tag `8.1.1`, commit `1d665c2b521512cdd56964138fc601debd1f1177` [up]. Licence MIT ("Old MIT").
- Source [dl]:
  - Tag archive (exact tree used today): `https://github.com/harfbuzz/harfbuzz/archive/refs/tags/8.1.1.tar.gz`, SHA-256 `b16e6bc0fc7e6a218583f40c7d201771f2e3072f85ef6e9217b36c1dc6b2aa25`, 35,438,503, embedded commit `1d665c2b`.
  - Release tarball: `https://github.com/harfbuzz/harfbuzz/releases/download/8.1.1/harfbuzz-8.1.1.tar.xz`, SHA-256 `0305ad702e11906a5fc0c1ba11c270b7f64a8f5390d676aacfd71db129d6565f`, 18,820,088.
  - No file present in both differs. The tarball adds autotools output and omits CI files, some documentation, `src/wasm`, `src/hb-wasm-api-list.hh`, several generator scripts and some test data.
- Build system: meson. Project defaults [up]: `cpp_eh=none`, `cpp_rtti=false`, `cpp_std=c++11`, `wrap_mode=nofallback`.
- Options passed [cfg]: `docs=disabled`, `freetype=disabled`, `glib=disabled`, `tests=disabled`.
- Options left at their defaults [up], with today's result in brackets:
  - `cairo=auto` (found on the build host), `chafa=auto`, `gobject=auto` (found on the build host), `icu=auto` (not found), `introspection=auto`
  - `benchmark=disabled`, `coretext=disabled`, `directwrite=disabled`, `gdi=disabled`, `graphite=disabled`, `graphite2=disabled`, `wasm=disabled`
  - `utilities=enabled`
  - `doc_tests=false`, `experimental_api=false`, `icu_builtin=false`, `ragel_subproject=false`
- Result [bin]:
  - `hb-features.h`: `HB_HAS_CAIRO 1` and `HB_HAS_GOBJECT 1`. `HB_HAS_CORETEXT`, `HB_HAS_DIRECTWRITE`, `HB_HAS_FREETYPE`, `HB_HAS_GDI`, `HB_HAS_GLIB`, `HB_HAS_GRAPHITE`, `HB_HAS_ICU`, `HB_HAS_UNISCRIBE` and `HB_HAS_WASM` are undefined.
  - `libharfbuzz.a` has 53 objects (the `hb-*.cc` core, OpenType layout, AAT, shapers, `hb-ucd`, `hb-static`). It has no cairo, GObject, GLib, ICU, CoreText or FreeType code. The Unicode functions come from the built-in `hb-ucd`.
  - Imports are libc (including `open`, `mmap` and `munmap` for loading font files into blobs, and locale functions), libm, pthread, `getenv` and `___assert_rtn`. Nothing comes from cairo, GLib, ICU, CoreText or FreeType.
- Packaging: the interim archive also contains `libharfbuzz-subset.a`, `libharfbuzz-cairo.a`, `libharfbuzz-gobject.a` and their `.pc` files. The xcframework ships only `libharfbuzz.a`.
- Installed headers: 37 under `harfbuzz/`, including `hb-cairo.h`, `hb-gobject.h`, `hb-gobject-structs.h` and `hb-subset*.h`. All are identical to upstream except the generated `hb-features.h` and `hb-gobject-enums.h`.
- pkg-config `harfbuzz.pc`:
  - `Name: harfbuzz`, `Version: 8.1.1`, no `Requires`
  - `Libs: -L${libdir} -lharfbuzz -lm`, `Cflags: -I${includedir}/harfbuzz`
- Source modifications: none.
- Official upstream Apple binary: none. The release has Windows zips only (`harfbuzz-win32-8.1.1.zip`, `harfbuzz-win64-8.1.1.zip`).

### 3.4 libunibreak 6.1

- Upstream `https://github.com/adah1972/libunibreak`, tag `libunibreak_6_1`, commit `304585d8e2d63187507368d612c3d5fff1486368` [up]. Licence zlib.
- Source [dl]:
  - Tag archive (exact tree used today): `https://github.com/adah1972/libunibreak/archive/refs/tags/libunibreak_6_1.tar.gz`, SHA-256 `890674996168ef5ba143d80d49ab8b61594a4eb70198dcac76caf6e1bd264a41`, 169,640, embedded commit `304585d8`.
  - Release tarball: `https://github.com/adah1972/libunibreak/releases/download/libunibreak_6_1/libunibreak-6.1.tar.gz`, SHA-256 `cc4de0099cf7ff05005ceabff4afed4c582a736abc38033e70fdac86335ce93f`, 855,733.
  - No file present in both differs. The tarball adds a generated `configure` and the autotools support files. The tag archive has `autogen.sh` and `bootstrap`, so the configure script is generated at build time, as it was today.
- Build system: autotools. Options [cfg]: `--disable-dependency-tracking`, `--disable-fast-install`, `--disable-shared`, `--enable-static`, and `--host=arm64-ios-darwin` (iOS device and simulator) or `--host=arm64-tvos-darwin` (tvOS device and simulator).
- Flags: exactly the cross flags of 1.4. No `-O` and no `-g`, so the code is unoptimised. Asserts are on.
- Result [bin]:
  - `libunibreak.a`, 9 objects (`libunibreak_la-*.o`): eastasianwidthdef, emojidef, graphemebreak, linebreak, linebreakdata, linebreakdef, unibreakbase, unibreakdef, wordbreak.
  - The interim archive also has a `liblinebreak.a`, which is not packaged.
  - 7 headers at the framework's `Headers/` root: `eastasianwidthdef.h`, `graphemebreak.h`, `linebreak.h`, `linebreakdef.h`, `unibreakbase.h`, `unibreakdef.h`, `wordbreak.h`. All are identical to upstream.
- pkg-config `libunibreak.pc`:
  - The shipped file's first line is a stray `libunibreak:`. Upstream's `libunibreak.pc.in` has that first line, so an upstream build reproduces it.
  - `Name: libunibreak`, `Version: 6.1`
  - `Libs: -L${libdir} -lunibreak`, `Cflags: -I${includedir}`
- Source modifications: none.
- Official upstream Apple binary: none.

### 3.5 libplacebo 7.351.0

- Upstream: primary `https://code.videolan.org/videolan/libplacebo`, official mirror `https://github.com/haasn/libplacebo`. Tag `v7.351.0`, annotated tag object `98c1416e95b21cd767b84ac9ee430ccadf263ff6`, commit `3188549fba13bbdf3a5a98de2a38c2e71f04e21e` [up]. Licence LGPL-2.1-or-later. The `-2512` suffix of today's interim release name is not part of the upstream ref.
- Source [dl]: `https://github.com/haasn/libplacebo/archive/refs/tags/v7.351.0.tar.gz`, SHA-256 `716954501d9b76e6906fddda66febc5886493d0673dd265ec1e6e52f4e5cd7c6`, 848,715, embedded commit `3188549f`. The archive's submodule directories are empty. Upstream publishes no release assets for this tag.
- Submodules at the tag (gitlinks) and their archives [up] [dl]:

| Path | Repository | Commit | Archive URL | SHA-256 | Size |
| --- | --- | --- | --- | --- | --- |
| `3rdparty/Vulkan-Headers` | `https://github.com/KhronosGroup/Vulkan-Headers` | `cacef3039d277c448c89336290ec3937270b0996` (tag `v1.4.310`, annotated tag object `5d69c1205417a928abcbda61b50b64d3e900e110`) | `https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.310.tar.gz` | `bfb970e74db66dc644c4f33ccef61cd69e057cda2950efc2f111c82c7ba98a6c` | 2,586,742 |
| | | | or `.../archive/cacef3039d277c448c89336290ec3937270b0996.tar.gz` | `400dc4bc49438f24ab9e90e6e587d9b1621a236f05eba80f6c048d7a1a96d353` | 2,587,521 |
| `3rdparty/fast_float` | `https://github.com/fastfloat/fast_float` | `1bf70101536d37fa9954cc4f03fd0903d045a9f3` | `https://github.com/fastfloat/fast_float/archive/1bf70101536d37fa9954cc4f03fd0903d045a9f3.tar.gz` | `95c7730f3db8bfb8568e26387bed5df5284158c408d2c6411ed8ad4f5a6dc9ae` | 121,291 |
| `3rdparty/glad` | `https://github.com/Dav1dde/glad` | `73db193f853e2ee079bf3ca8a64aa2eaf6459043` | `https://github.com/Dav1dde/glad/archive/73db193f853e2ee079bf3ca8a64aa2eaf6459043.tar.gz` | `33dbeae44d8315ece57e14eba4b1b4a02ac5406d1c4f49cd20048c91522a6b9a` | 645,779 |
| `3rdparty/jinja` | `https://github.com/pallets/jinja` | `15206881c006c79667fe5154fe80c01c65410679` | `https://github.com/pallets/jinja/archive/15206881c006c79667fe5154fe80c01c65410679.tar.gz` | `b88a20dcc2e34072fcf4159325bc6c34cd4b29a81a8b83d15d2f28ba561da296` | 276,954 |
| `3rdparty/markupsafe` | `https://github.com/pallets/markupsafe` | `28ace20b140d15c083e1cbc163ee6b7778ba098c` | `https://github.com/pallets/markupsafe/archive/28ace20b140d15c083e1cbc163ee6b7778ba098c.tar.gz` | `bead4c1f90f02956a082c6f026237e1e106a00636f4b26c3f16921631eb8737f` | 24,685 |

- The tag also has `demos/3rdparty/nuklear` (`b0fbe40b943e735150465875d81e4ed0562359a8`). It was present in today's tree but is unused, because demos are off.
- jinja and markupsafe are build-time code-generator inputs only. The build host also had Python 3 with `jinja2` installed.
- Build system: meson. Project defaults [up]: `buildtype=debugoptimized` (overridden to `release`), `warning_level=2`, `c_std=c11`, `cpp_std=c++20`.
- Options passed [cfg]: `d3d11=disabled`, `demos=false`, `dovi=enabled`, `glslang=disabled`, `lcms=enabled`, `libdovi=enabled`, `opengl=enabled`, `shaderc=enabled`, `tests=false`, `unwind=disabled`, `vulkan=enabled`, `xxhash=disabled`.
- Options left at their defaults [up], with today's result in brackets: `bench=false`, `debug-abort=false`, `fuzz=false`, `gl-proc-addr=auto` (enabled), `vk-proc-addr=auto` (enabled), `vulkan-registry=''` (`3rdparty/Vulkan-Headers/registry/vk.xml`).
- Build-time inputs: shaderc (combined `shaderc.pc`), MoltenVK's `vulkan.pc` (1.4.334, used to link `vkGetInstanceProcAddr` directly), lcms2 2.17 and libdovi 3.3.2. Today these were the interim prebuilt builds of 1.2 and an interim prebuilt libdovi 3.3.2. Compilation used the `3rdparty/Vulkan-Headers` submodule (v1.4.310), not MoltenVK's headers.
- Result `config.h` [bin]:
  - `PL_MAJOR_VER 7`, `PL_API_VER 351`
  - Defined as 1: `PL_HAVE_DOVI`, `PL_HAVE_GL_PROC_ADDR`, `PL_HAVE_LCMS`, `PL_HAVE_LIBDOVI`, `PL_HAVE_OPENGL`, `PL_HAVE_SHADERC`, `PL_HAVE_VK_PROC_ADDR`, `PL_HAVE_VULKAN`
  - Undefined: `PL_HAVE_D3D11`, `PL_HAVE_GLSLANG`, `PL_HAVE_XXHASH`
- Version string compiled in: `v7.351.0 (v7.351.0-dirty)`. It is produced by upstream's `version.py` from `git describe --dirty`; the tree counts as dirty because of the modification below.
- Objects (56):
  - core: cache, colorspace, common, `convert.cc` (fast_float), dispatch, dither, filters, format, gamut_mapping, log, options, pl_alloc, pl_string, swapchain, tone_mapping
  - GLSL to SPIR-V: glsl_spirv, glsl_spirv_shaderc
  - gpu, gpu_utils
  - generated: renderer, shaders and its sub-parts, `vulkan_utils_gen`
  - OpenGL backend: context, formats, gpu, gpu_pass, gpu_tex, `loader_egl`, `loader_gl`, swapchain, utils
  - Vulkan backend: command, context, formats, gpu, gpu_buf, gpu_pass, gpu_tex, malloc, swapchain, utils
  - utils: dolbyvision, frame_queue, upload
- Installed headers: 34 under `libplacebo/`. 33 are identical to upstream `src/include/libplacebo/`; the 34th is the generated `config.h`.
- pkg-config `libplacebo.pc`:
  - Variables: `pl_has_d3d11=0`, `pl_has_dovi=1`, `pl_has_gl_proc_addr=1`, `pl_has_glslang=0`, `pl_has_lcms=1`, `pl_has_libdovi=1`, `pl_has_opengl=1`, `pl_has_shaderc=1`, `pl_has_vk_proc_addr=1`, `pl_has_vulkan=1`, `pl_has_xxhash=0`
  - `Name: libplacebo`, `Version: 7.351.0`
  - `Requires: shaderc >= 2019.1, vulkan, lcms2 >= 2.9, dovi >= 1.6.7`
  - `Libs: -L${libdir} -lplacebo -lm -ldl`, `Cflags: -I${includedir} -DPL_HAVE_PTHREAD -DPL_STATIC`
- Source modification: one change, identical to upstream libplacebo commit `a22f0dff5fe89385155743a1735b146babfdb131` (29 July 2025, "vulkan/utils_gen: fix for python 3.14"). It lets the build-time Vulkan code generator parse the registry under Python 3.14. The generated code is unchanged, so its only effect on the binary is the `-dirty` version string above.
- Official upstream Apple binary: none.

### 3.6 Little CMS 2.17

- Upstream `https://github.com/mm2/Little-CMS`, tag `lcms2.17`, commit `5176347635785e53ee5cee92328f76fda766ecc6` [up]. Licence MIT. `LCMS_VERSION 2170`.
- Source [dl]:
  - Tag archive (exact tree used today): `https://github.com/mm2/Little-CMS/archive/refs/tags/lcms2.17.tar.gz`, SHA-256 `6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418`, 5,257,509, embedded commit `51763476`.
  - Release tarball: `https://github.com/mm2/Little-CMS/releases/download/lcms2.17/lcms2-2.17.tar.gz`, SHA-256 `d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074`, 5,245,319.
  - No file present in both differs. The tarball adds only `.deps` directories and `setup`.
- Build system: meson, with no library options passed [cfg]. Defaults apply [up]: `fastfloat=false`, `jpeg=auto`, `tests=enabled`, `threaded=false`, `tiff=auto`, `utils=false`. jpeg and tiff matter only to the utilities, which are not built. The GPL-3.0 fast_float and threaded plug-ins are not built.
- Result [bin]: 26 objects, asserts on, imports include pthread. Headers `lcms2.h` and `lcms2_plugin.h`, both identical to upstream.
- pkg-config `lcms2.pc`:
  - `Name: lcms2`, `Version: 2.17`
  - `Libs: -L${libdir} -llcms2 -lm`, `Cflags: -I${includedir}`
- Source modifications: none.
- Official upstream Apple binary: none. The release has source `.tar.gz` and `.zip` only.

### 3.7 MoltenVK 1.4.1

- Upstream `https://github.com/KhronosGroup/MoltenVK`, tag `v1.4.1` (lightweight), commit `db445ff2042d9ce348c439ad8451112f354b8d2a`; release published 30 November 2025 [up] [ci]. Licence Apache-2.0. `MVK_VERSION 1.4.1`.
- Source [dl]: `https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.1.tar.gz`, SHA-256 `9985f141902a17de818e264d17c1ce334b748e499ee02fcb4703e4dc0038f89c`, 1,249,866, embedded commit `db445ff2`.
- Externals pinned in `ExternalRevisions/` at the tag, with archives [up] [dl]:

| External | Repository | Revision | Archive | SHA-256 | Size |
| --- | --- | --- | --- | --- | --- |
| SPIRV-Cross | `https://github.com/KhronosGroup/SPIRV-Cross` | `adec7acbf41a988713cdb85f93f26c8ca5ea863e` (13 November 2025, not a tag) | `.../SPIRV-Cross/archive/adec7acbf41a988713cdb85f93f26c8ca5ea863e.tar.gz` | `1bed78fb2c43c877058c21bf1d9bfa2332df935960c6901bb141f4ef34cd9f03` | 1,952,650 |
| SPIRV-Headers | `https://github.com/KhronosGroup/SPIRV-Headers` | `b824a462d4256d720bebb40e78b9eb8f78bbb305` (tag `vulkan-sdk-1.4.335.0`) | `.../SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.335.0.tar.gz` | `1c47ca6342ebe86f57b46b8dbeb266fa655a1ca8e10d07e45370ff2d9c36312e` | 558,628 |
| | | | or `.../SPIRV-Headers/archive/b824a462d4256d720bebb40e78b9eb8f78bbb305.tar.gz` | `c693867f10a7760ef1bcf85419d51783586768cc2c601d03841bc6a8b2554b9c` | 558,965 |
| SPIRV-Tools | `https://github.com/KhronosGroup/SPIRV-Tools` | `262bdab48146c937467f826699a40da0fdfc0f1a` (tags `v2025.5` and `vulkan-sdk-1.4.335.0`) | `.../SPIRV-Tools/archive/refs/tags/v2025.5.tar.gz` | `23769a70967e91f16f1bf8a58665b643fc4e765d734e85c51faa7d990f01a64f` | 3,422,476 |
| | | | or `.../SPIRV-Tools/archive/262bdab48146c937467f826699a40da0fdfc0f1a.tar.gz` | `8f830936b057003be77e90d37068ff6066eb87a1bab0033f8f2f5feaa966ce56` | 3,428,734 |
| Vulkan-Headers | `https://github.com/KhronosGroup/Vulkan-Headers` | `6aefb8eb95c8e170d0805fd0f2d02832ec1e099a` (tag `v1.4.334`, annotated tag object `23af78620443efa5ab7d7d5e0a4f71cbb0229f36`) | `.../Vulkan-Headers/archive/refs/tags/v1.4.334.tar.gz` | `f6b858ed8ff5747a32e7840ba20c565c6477c5c1c171bfc25195ef1730b349cc` | 2,854,696 |
| Vulkan-Tools | `https://github.com/KhronosGroup/Vulkan-Tools` | `013058f74e2356347f8d9317233bc769816c9dfb` | `.../Vulkan-Tools/archive/013058f74e2356347f8d9317233bc769816c9dfb.tar.gz` | `1e099b6a945109d33e8e078fc5a226377bb130175786273ce1594a840331c64c` | 790,238 |
| Volk | `https://github.com/zeux/volk` | `59660878571aa99e3c9a366bb1d19fdcd701f0e7` | `https://github.com/zeux/volk/archive/59660878571aa99e3c9a366bb1d19fdcd701f0e7.tar.gz` | `2917f61cce3354733e880a0294129fc172eccb07a6d90cc45841fafbf192db00` | 79,072 |
| cereal | `https://github.com/USCiLab/cereal` | `a56bad8bbb770ee266e930c95d37fff2a5be7fea` | `https://github.com/USCiLab/cereal/archive/a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz` | `12e10fb541270632f6683286ce8c7e8c321fe4addb53fa91ed498b95c1758f93` | 386,830 |

- Upstream fetches SPIRV-Headers into `SPIRV-Tools/external/spirv-headers`.
- Compiled into `libMoltenVK.a` [bin]:
  - SPIRV-Cross, in namespace `MVK_spirv_cross`
  - SPIRV-Tools (`spvtools`), built by upstream from its pre-generated header template
  - cereal (headers)
  - Vulkan-Headers and SPIRV-Headers (headers)
  - No Volk or Vulkan-Tools code is present.
- Build [cfg]: upstream's documented procedure, with nothing else passed.
  - `fetchDependencies` with one platform flag each for Vivid's slices: `--ios --iossim --tvos --tvossim`.
  - Upstream's `Makefile` targets for the same platforms (`ios iossim tvos tvossim`), with no command-line `MVK_*` variables, so no extra preprocessor definitions.
  - Today's xcframework also has macOS, Mac Catalyst and visionOS slices, which Vivid does not use.
  - The output is upstream's static package, `Package/Release/MoltenVK/static/MoltenVK.xcframework`.
- Upstream project settings that apply (Release) [up]:
  - `GCC_OPTIMIZATION_LEVEL=2`, `GCC_PREPROCESSOR_DEFINITIONS` `NDEBUG=1`, `SPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross`, `MVK_FRAMEWORK_VERSION=1.4.1`
  - `ENABLE_NS_ASSERTIONS=NO`, `GCC_GENERATE_DEBUGGING_SYMBOLS=NO`, `GCC_SYMBOLS_PRIVATE_EXTERN=YES`, `GCC_INLINES_ARE_PRIVATE_EXTERN=YES`, `GCC_NO_COMMON_BLOCKS=YES`
  - `GENERATE_MASTER_OBJECT_FILE=YES`, which prelinks MoltenVKShaderConverter into a single master object
  - `IPHONEOS_DEPLOYMENT_TARGET=14.0`, `TVOS_DEPLOYMENT_TARGET=14.5`
- SDK-dependent code [up] [bin]:
  - MoltenVK compiles feature paths under `MVK_XCODE_16` (iOS or tvOS SDK 18.0 or later) and `MVK_XCODE_26` (SDK 26.0 or later). Each is defined only if not already defined.
  - Today's binary was compiled with SDK 17.5, so both are 0. It has no residency-set, Metal math-mode, Metal 4 or Apple10 code.
- Revision string [up] [bin]: upstream's build writes a generated header holding the output of `git rev-parse HEAD`. Today's binary contains `db445ff2042d9ce348c439ad8451112f354b8d2a`, and the first 8 characters feed the pipeline-cache UUID MoltenVK reports to Vulkan applications (D13).
- Source modification, by effect [bin]: Apple GPU family 9 is never detected, on any platform, iOS included.
  - Today's device-capability set-up queries GPU families Apple1 to Apple8 only (family values 1001 to 1008 in the disassembly). Upstream also queries Apple9 (1009).
  - On any device whose GPU is family 9 or newer (for example A17 Pro, A18 and M3 or later), MoltenVK therefore applies the pre-family-9 capability restriction to the `R32Float`, `RG32Float` and `RGBA32Float` pixel formats.
  - This supersedes the description in `lucid-engine-build-facts.md` 2.8.
- Result [bin]:
  - One prelinked object; 565 exported symbols, all default visibility, of which 431 are `vk*`.
  - 36 static-initialiser entries (35 C++ global constructors).
  - Imports: Metal (classes, `MTLCreateSystemDefaultDevice`), QuartzCore (`CAMetalLayer`, `kCAGravity*`, `kCAFilter*`), IOSurface, CoreGraphics colour spaces, CoreFoundation, Foundation, UIKit (`UIScreen`, `UIView`), libdispatch, the libc++ and C++ ABI runtime, pthread and libc.
- Shipped for consumers [bin]:
  - The xcframework is library type (`libMoltenVK.a`, no headers or module).
  - The interim archive `MoltenVK-all.zip` adds `include/` with `vulkan/`, `vk_video/` and `MoltenVK/` (`VK_HEADER_VERSION 334`) and a generated `vulkan.pc`.
  - `vulkan.pc` is not produced by MoltenVK. Its fields: `Name: Vulkan-Loader` and `Description: Vulkan Loader` (the same as Khronos Vulkan-Loader's own `vulkan.pc`), `Version: 1.4.334`, `Cflags: -I${includedir}`, and `Libs`:
    - iOS device and simulator slices: `-L${libdir} -lMoltenVK -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit -framework IOKit`
    - tvOS device and simulator slices: `-L${libdir} -lMoltenVK -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit`
- Official upstream Apple binary: yes, see section 4.

### 3.8 shaderc 2025.5

- Upstream `https://github.com/google/shaderc`, tag `v2025.5` (annotated), commit `c4b0af6c3664cd8b33ffddf452514e02a173b4d6` [up]. Licence Apache-2.0. There is no GitHub release for the tag.
- Source [dl]: `https://github.com/google/shaderc/archive/refs/tags/v2025.5.tar.gz`, SHA-256 `fca5041b1fdea6daba167b63e04e55e5059fab40828342126169336643445447`, 228,956, embedded commit `c4b0af6c`.
- Third-party sources pinned in `DEPS` and fetched into `third_party/` [up] [dl]:

| Directory | Repository | Commit | Archive SHA-256 | Size |
| --- | --- | --- | --- | --- |
| `third_party/glslang` | `https://github.com/KhronosGroup/glslang` | `7a47e2531cb334982b2a2dd8513dca0a3de4373d` (25 November 2025, after tag 16.0.0 and before 16.1.0; reports `GLSLANG_VERSION` 16.0.0) | `https://github.com/KhronosGroup/glslang/archive/7a47e2531cb334982b2a2dd8513dca0a3de4373d.tar.gz` `272d2725b140e09e85b96eecdc59c2e00c1a14cda2301767e1bf3c363a44b931` | 4,250,661 |
| `third_party/spirv-tools` | `https://github.com/KhronosGroup/SPIRV-Tools` | `262bdab48146c937467f826699a40da0fdfc0f1a` (tag `v2025.5`) | as in 3.7 | |
| `third_party/spirv-headers` | `https://github.com/KhronosGroup/SPIRV-Headers` | `b824a462d4256d720bebb40e78b9eb8f78bbb305` (tag `vulkan-sdk-1.4.335.0`) | as in 3.7 | |
| `third_party/abseil_cpp`, `effcee`, `googletest`, `re2` | abseil, google | `1315c900e1ddbb08a23e06eeb9a06450052ccb5e`, `08da24ec245a274fea3a128ba50068f163390565`, `1d17ea141d2c11b8917d2c7d029f1c4e2b9769b2`, `4a8cee3dd3c3d81b6fe8b867811e193d5819df07` | test-only; nothing from them is in the library (0 matching symbols) | |

- MoltenVK 1.4.1 pins the same SPIRV-Tools and SPIRV-Headers commits.
- Build system: CMake. Options [cfg]: `BUILD_SHARED_LIBS=OFF`, `ENABLE_EXCEPTIONS=ON`, `ENABLE_GLSLANG_BINARIES=OFF`, `SHADERC_SKIP_COPYRIGHT_CHECK=ON`, `SHADERC_SKIP_EXAMPLES=ON`, `SHADERC_SKIP_TESTS=ON`, `SPIRV_SKIP_EXECUTABLES=ON`, `SPIRV_TOOLS_BUILD_STATIC=ON`, plus the common values of 1.4.
- Options left at their defaults [up]: `SHADERC_ENABLE_WERROR_COMPILE=ON`, `SHADERC_ENABLE_WGSL_OUTPUT=OFF`, `SHADERC_SKIP_EXECUTABLES` (unset, so `glslc` is built but not shipped).
- Source modification, by effect: two SPIRV-Tools command-line tool sources (the reducer and the fuzzer) were changed so they no longer call `std::system`, which tvOS lacks. Those tools are not built (`SPIRV_SKIP_EXECUTABLES=ON`), so no shipped object changes, and an unmodified upstream tree gives the same library.
- Result [bin]:
  - `libshaderc_combined.a`, upstream's combined target: shaderc, shaderc_util, glslang (with SPIRV, MachineIndependent, GenericCodeGen, OSDependent), SPIRV-Tools and SPIRV-Tools-opt.
  - 250 objects, 45 `shaderc_*` entry points, libc++.
  - 4 static initialisers, from glslang `Scan.cpp`, `ShaderLang.cpp`, `doc.cpp` and `hlslScanContext.cpp`.
  - Version strings compiled in: SPIRV-Tools `v2025.5` and `SPIRV-Tools v2025.5 v2025.5-0-g262bdab4`, generated from the CHANGES file and `git describe` of the SPIRV-Tools checkout (D13). glslang reports `16.0.0`.
  - The interim archive also has the separate glslang and SPIRV-Tools archives, which are not packaged.
- Headers: `glslang/` (with `build_info.h`, `GLSLANG_VERSION_MAJOR 16`, `_MINOR 0`, `_PATCH 0`), `shaderc/` (`env.h`, `shaderc.h`, `shaderc.hpp`, `status.h`, `visibility.h`) and `spirv-tools/` (`libspirv.h`, `libspirv.hpp`, `linker.hpp`, `optimizer.hpp`).
- pkg-config:
  - Consumers need a file named `shaderc.pc` with the content of upstream's combined variant (which upstream installs as `shaderc_combined.pc`): `Name: shaderc`, `Version: 2023.8.1` (upstream's version string at this tag), `Libs: -L${libdir} -lshaderc_combined`, `Cflags: -I${includedir}`.
  - Today's interim archive also carries upstream's non-combined `shaderc.pc` under another name; no consumer uses it.
  - `SPIRV-Tools.pc` is version 2025.5.1.
- Official upstream Apple binary: none.

### 3.9 uavs3d 1.2

- Upstream `https://github.com/uavs3/uavs3d`, lightweight tag `1.2`, commit `0e20d2c291853f196c68922a264bcd8471d75b68` (committed 13 December 2025) [up] [ci].
  - Today's binary was built on 25 July 2026 from that commit.
  - The GitHub release `uavs3d_1.2` for the tag was published on 10 August 2026 and has no assets.
  - Licence: three-clause BSD (`COPYING`).
- Source [dl]:
  - `https://github.com/uavs3/uavs3d/archive/refs/tags/1.2.tar.gz`, SHA-256 `faa1f1f82badc0603d9944bb5af7b961dd42236e2c3a7aa8fcfc080bbeb5b157`, 629,262, embedded commit `0e20d2c2`.
  - Same tree by commit: `.../archive/0e20d2c291853f196c68922a264bcd8471d75b68.tar.gz`, SHA-256 `1c1eb778b6080bc01493180ea7ae671c6444ce3aa760b5d021ba882eb0f9e3a0`, 629,567.
- Build system: CMake. Options [cfg]: `COMPILE_10BIT=1`, plus the common values of 1.4.
  - Upstream sets C99 and position-independent code.
  - `CMAKE_SYSTEM_PROCESSOR=arm64` selects upstream's arm64 sources: 10 NEON assembly files (alf, deblock, def, inter_pred, intra_pred, intra_pred_chroma, itrans_dct2, itrans_dct8_dst7, pixel, sao_kernel) and `arm64.c`, `itrans_arm64.c`, `sao_arm64.c`.
- Version metadata [up] [bin]:
  - Upstream's CMake runs `version.sh` from the CMake build directory. It writes `version.h` from `git rev-list` and `git log` in whatever repository contains that directory.
  - Today that directory was inside a third-party build repository's checkout with a single commit. So `version.h` held `VER_MAJOR 1`, `VER_MINOR 2`, `VER_BUILD 1`, `VERSION_STR "1.2.1"`, `VERSION_TYPE "release"`, and in `VERSION_SHA1` that repository's 40-hex commit id, a third-party build identifier. Vivid's build has no Git history to read: its uavs3d patch `0001` writes the same values and, in `VERSION_SHA1`, uavs3d's own commit for tag 1.2, `0e20d2c291853f196c68922a264bcd8471d75b68`, which `lucid.py check` requires in the binary.
  - `uavs3d_create` prints `libuavs3d(10): 1.2.1_release, <VERSION_SHA1>` to standard output every time it is called. The bit depth 10 in that call confirms `COMPILE_10BIT=1` in the binary.
  - `VERSION_STR` is also the `.pc` version.
- Source modification, by effect: the `uavs3dec` test program is not built. The library is unaffected.
- Today's interim uavs3d release (named `1.2.1-fix`, 25 July 2026) is a rebuild that adds a Mac Catalyst slice [ci]. Its build environment sets the minimum OS to 15.0 (1.3). It does not change uavs3d's source.
- Result [bin]:
  - 29 objects (19 C, 10 assembly); all 266 exported symbols have default visibility; imports include pthread. No asserts.
  - The header `uavs3d.h` is identical to upstream `source/decoder/uavs3d.h`.
- pkg-config `uavs3d.pc`:
  - `Name: uavs3d`, `Description: AVS3 decoder library`, `Version: 1.2.1`
  - `Libs: -L${libdir} -luavs3d -lm -lpthread`, `Cflags: -I${includedir}`
- Official upstream Apple binary: none.

### 3.10 libbluray 1.4.0 (with libudfread 1.2.0)

- Upstream: `https://code.videolan.org/videolan/libbluray`, tag `1.4.0`, annotated tag object `0852c0eac309d435f4334baf168620fece742359`, commit `9f07fbb2077be7a40b062bcf2463a9941c2a3b13` [up]. Licence LGPL-2.1-or-later. There is no GitHub repository for libbluray or libudfread under `github.com/videolan`.
- Submodule `contrib/libudfread`: `https://code.videolan.org/videolan/libudfread`, tag `1.2.0`, annotated tag object `4469d721d7a192cccaff817b187eafc6c27238c6`, commit `c3cd5cbb097924557ea4d9da1ff76a74620c51a8`. Licence LGPL-2.1-or-later.
- Source [dl]:
  - Release tarball: `https://download.videolan.org/pub/videolan/libbluray/1.4.0/libbluray-1.4.0.tar.xz`, SHA-256 `77937baf07eadda4b2b311cf3af4c50269d2ea3165041f5843d96476c4c92777`, 458,580.
    - Its SHA-512 (`7284169b32624e5ca4fd71b260a4cc2921efafb1f63143a562568be45e373bfcbfeac63895d5659ccdcb11d7dbd0236cc46ccb15c12eff855703010e46991f27`) equals the published `.sha512` file.
    - It contains `contrib/libudfread` already filled in, identical to libudfread at `c3cd5cbb`.
    - Apart from that content, it is identical to the tag tree.
  - GitLab tag archive: `https://code.videolan.org/videolan/libbluray/-/archive/1.4.0/libbluray-1.4.0.tar.gz`, SHA-256 `0dc218f79435798a62da2a0510e0e921a3f7c1b140507df8e65f48d98046f024`, 593,766, embedded commit `9f07fbb2`. Its `contrib/libudfread` is empty.
  - libudfread on its own: `https://download.videolan.org/pub/videolan/libudfread/libudfread-1.2.0.tar.xz`, SHA-256 `bb477cbd4cfbfc7787d9d05b71ee5e70430f5cfebf1297497f7e83547958050f`, 28,732. Its SHA-512 equals the published `.sha512`.
  - libudfread GitLab commit archive: `https://code.videolan.org/videolan/libudfread/-/archive/c3cd5cbb097924557ea4d9da1ff76a74620c51a8/libudfread-c3cd5cbb097924557ea4d9da1ff76a74620c51a8.tar.gz`, SHA-256 `cad9c997dda97a5bc9e0e01a664fd8ac9deb227bca09124f87666ed1e4d4dba6`, 32,788. Its content is identical to the release tarball.
  - GitLab creates its archives on request; the hashes above are as downloaded on 13 October 2026.
- Build system: meson. Options [cfg]: `bdj_jar=disabled`, `embed_udfread=true`, `enable_devtools=false`, `enable_docs=false`, `enable_examples=false`, `enable_tools=false`, `fontconfig=disabled`, `freetype=enabled`, `java9=false`, `libxml2=enabled`. Defaults left: `bdj_bootclasspath=''`, `bdj_type=j2se`, `jdk_home=''`.
- Resolved inputs:
  - FreeType: the 2.12.1 build of 3.1.
  - libxml2: through the build host's pkg-config file for the macOS SDK's libxml2 (headers from the macOS SDK); linked at app link time against the target SDK's libxml2.
- Result [bin], 59 objects:
  - navigation and parsers
  - HDMV virtual machine
  - decoders, including the TextST renderer, which uses FreeType
  - disc access, with AACS and BD+ through `dlopen` of external libraries
  - BD-J native glue (`bdj.c`, bdjo, JNI natives). It is compiled, but no Java runtime or BD-J jar is shipped.
  - embedded libudfread (`udfread`, `ecma167`, `default_blockinput`, `udfread-version`)
  - Darwin file helpers
  - Imports: FreeType (9 symbols), libxml2 (8), `dlopen`/`dlsym`/`dladdr`, pthread mutexes. No OpenSSL, DiskArbitration, `fork`, `vfork` or `exec*`.
- Why a change is needed: unmodified upstream 1.4.0 does not build for these SDKs. On Darwin hosts its meson build requires the DiskArbitration framework, and its Darwin mount helper includes a DiskArbitration header; the iOS and tvOS SDKs have no DiskArbitration. On tvOS, `vfork` and `execl`, which the Java-home lookup uses, are unavailable.
- Source modifications, by effect, on iOS and tvOS only (macOS is unchanged):
  1. The mount-point lookup for a block device through DiskArbitration is not performed and returns no mount point. The DiskArbitration framework is not linked; only CoreFoundation is.
  2. The macOS method of finding a Java home by running a helper process never spawns that process and behaves as if spawning failed.
- Installed headers: 9 under `libbluray/`. 8 are identical to upstream; `bluray-version.h` is generated.
- pkg-config `libbluray.pc`:
  - `Name: libbluray`, `Version: 1.4.0`, `Requires: freetype2, libxml-2.0 >= 2.6`
  - `Libs: -L${libdir} -lbluray -framework CoreFoundation`, `Cflags: -I${includedir}`
- Official upstream Apple binary: none.

### 3.11 uchardet 0.0.8

- Upstream: `https://gitlab.freedesktop.org/uchardet/uchardet`, tag `v0.0.8` (annotated), commit `ae6302a016088ad07177f86d417b20010053632b` [up]. Licence MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later, used under LGPL-2.1-or-later. There is no GitHub repository under `github.com/freedesktop`.
- Source [dl]:
  - Release tarball: `https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz`, SHA-256 `e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0`, 222,648. This equals the published `.sha256` file.
  - GitLab tag archive: `https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v0.0.8/uchardet-v0.0.8.tar.gz`, SHA-256 `5aa402a1b5b1dbb8d81096f141ff1224e079f4d3a1db0f79ecca782756d3a416`, 330,014, embedded commit `ae6302a0`.
  - The two trees are identical (no file differs or is missing).
- Build system: CMake. Options [cfg]: `BUILD_BINARY=0`, plus the common values of 1.4 (`BUILD_SHARED_LIBS=0`, `Release`). Defaults left [up]: `BUILD_STATIC=ON` and `CHECK_SSE2=ON` (affects x86 only).
- Today's interim uchardet release (named `0.0.8-xcode`) [ci]: its suffix marks build-configuration changes only (architecture lists and Xcode version). Its assets were built with Xcode 15.4. In its xcframework, arm64e appears only in the tvOS device slice (alongside arm64), as in the other libraries' xcframeworks. Nothing changes uchardet's source.
- Result [bin]: 50 objects, C++ (libc++), no asserts. The header `uchardet/uchardet.h` is identical to upstream.
- pkg-config `uchardet.pc`:
  - `Name: uchardet`, `Version: 0.0.8`, `Requires:` (empty)
  - `Libs: -L${libdir} -luchardet`, `Libs.private: -lstdc++`, `Cflags: -I${includedir}/uchardet`
- Official upstream Apple binary: none.

---

## 4. Official upstream Apple binaries

### 4.1 MoltenVK: yes

Khronos publishes prebuilt MoltenVK with the GitHub release `v1.4.1` [ci] [dl]:

The two macOS rows are GitHub's asset digests only; those files were not downloaded. The first two were downloaded, and their SHA-256 equals GitHub's digest.

| Asset | URL | SHA-256 | Size |
| --- | --- | --- | --- |
| `MoltenVK-all.tar` | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar` | `2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557` | 173,033,984 |
| `MoltenVK-ios.tar` | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-ios.tar` | `54336b90212c390ed5935c96460aed3bf651ad7d3c0f0e956586ce18e9c0b701` | 31,771,648 |
| `MoltenVK-macos.tar` | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-macos.tar` | `5ea0c259df7ded9a275444820f09cced54d6e5a7c7a31d262de62a5cdb7e15cf` | 56,034,304 |
| `MoltenVK-macos-privateapi.tar` | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-macos-privateapi.tar` | `5e662d77f7f280d9bd692ac5d626831198f404e28b0c8d4d11aac04bff8ff418` | 56,060,928 |

There is no tvOS-only asset. `MoltenVK-all.tar` (downloaded and inspected) contains `MoltenVK/MoltenVK/static/MoltenVK.xcframework` and `MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework`, plus `include/`, `Docs/` and `LICENSE`.

The static xcframework's library identifiers are `ios-arm64`, `ios-arm64_x86_64-simulator`, `tvos-arm64_arm64e`, `tvos-arm64_x86_64-simulator`, `macos-arm64_x86_64`, `xros-arm64` and `xros-arm64_x86_64-simulator`. Each holds `libMoltenVK.a`, so Vivid's four slices are all present.

Comparison with today's binary (ios-arm64 arm64 member) [bin]:
- Same: one prelinked master object; the same 565 exported symbols; `minos` iOS 14.0 and tvOS 14.5.
- It was built with SDK 18.5, not 17.5. So `MVK_XCODE_16` paths are compiled in: it imports `MTLResidencySetDescriptor` and the residency-set, allocation and math-mode selectors, which today's does not. `MVK_XCODE_26` paths are not.
- It queries Apple GPU family 9, which today's does not (3.7).
- Its arm64 archive sizes differ: ios-arm64 6,859,952 bytes against today's 6,924,256.
- Using it would therefore change MoltenVK's run-time behaviour on iOS 18 or tvOS 18 and later and on family-9 GPUs. None of that is reached in Vivid's playback today (B).

### 4.2 The other ten: none

- HarfBuzz 8.1.1: Windows zips only.
- FriBidi, libunibreak, Little CMS: source archives only.
- libplacebo, uavs3d, shaderc and the FreeType GitHub mirror: no assets for these tags. shaderc has no GitHub release for `v2025.5`, and uavs3d's release `uavs3d_1.2` has no assets.
- libbluray, libudfread and uchardet: source tarballs on their own servers only.
- No official prebuilt binary for any Apple platform was found for any of these ten.

---

## 5. Source archives in one list

All downloaded on 13 October 2026. "Commit" is the id GitHub or GitLab embeds in the archive (`git get-tar-commit-id`); release tarballs embed none.

| Library | Archive URL | SHA-256 | Commit |
| --- | --- | --- | --- |
| FreeType | `https://github.com/freetype/freetype/archive/refs/tags/VER-2-12-1.tar.gz` | `0e72cae32751598d126cfd4bceda909f646b7231ab8c52e28abb686c20a2bea1` | `e8ebfe988b5f57bfb9a3ecb13c70d9791bce9ecf` |
| FreeType (release) | `https://download.savannah.gnu.org/releases/freetype/freetype-2.12.1.tar.xz` | `4766f20157cc4cf0cd292f80bf917f92d1c439b243ac3018debf6b9140c41a7f` | |
| FriBidi | `https://github.com/fribidi/fribidi/archive/refs/tags/v1.0.12.tar.gz` | `2e9e859876571f03567ac91e5ed3b5308791f31cda083408c2b60fa1fe00a39d` | `6428d8469e536bcbb6e12c7b79ba6659371c435a` |
| FriBidi (release) | `https://github.com/fribidi/fribidi/releases/download/v1.0.12/fribidi-1.0.12.tar.xz` | `0cd233f97fc8c67bb3ac27ce8440def5d3ffacf516765b91c2cc654498293495` | |
| HarfBuzz | `https://github.com/harfbuzz/harfbuzz/archive/refs/tags/8.1.1.tar.gz` | `b16e6bc0fc7e6a218583f40c7d201771f2e3072f85ef6e9217b36c1dc6b2aa25` | `1d665c2b521512cdd56964138fc601debd1f1177` |
| HarfBuzz (release) | `https://github.com/harfbuzz/harfbuzz/releases/download/8.1.1/harfbuzz-8.1.1.tar.xz` | `0305ad702e11906a5fc0c1ba11c270b7f64a8f5390d676aacfd71db129d6565f` | |
| libunibreak | `https://github.com/adah1972/libunibreak/archive/refs/tags/libunibreak_6_1.tar.gz` | `890674996168ef5ba143d80d49ab8b61594a4eb70198dcac76caf6e1bd264a41` | `304585d8e2d63187507368d612c3d5fff1486368` |
| libunibreak (release) | `https://github.com/adah1972/libunibreak/releases/download/libunibreak_6_1/libunibreak-6.1.tar.gz` | `cc4de0099cf7ff05005ceabff4afed4c582a736abc38033e70fdac86335ce93f` | |
| libplacebo (and its five submodules, 3.5) | `https://github.com/haasn/libplacebo/archive/refs/tags/v7.351.0.tar.gz` | `716954501d9b76e6906fddda66febc5886493d0673dd265ec1e6e52f4e5cd7c6` | `3188549fba13bbdf3a5a98de2a38c2e71f04e21e` |
| Little CMS | `https://github.com/mm2/Little-CMS/archive/refs/tags/lcms2.17.tar.gz` | `6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418` | `5176347635785e53ee5cee92328f76fda766ecc6` |
| Little CMS (release) | `https://github.com/mm2/Little-CMS/releases/download/lcms2.17/lcms2-2.17.tar.gz` | `d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074` | |
| MoltenVK (and its seven externals, 3.7) | `https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.1.tar.gz` | `9985f141902a17de818e264d17c1ce334b748e499ee02fcb4703e4dc0038f89c` | `db445ff2042d9ce348c439ad8451112f354b8d2a` |
| shaderc (and glslang, SPIRV-Tools, SPIRV-Headers, 3.8) | `https://github.com/google/shaderc/archive/refs/tags/v2025.5.tar.gz` | `fca5041b1fdea6daba167b63e04e55e5059fab40828342126169336643445447` | `c4b0af6c3664cd8b33ffddf452514e02a173b4d6` |
| uavs3d | `https://github.com/uavs3/uavs3d/archive/refs/tags/1.2.tar.gz` | `faa1f1f82badc0603d9944bb5af7b961dd42236e2c3a7aa8fcfc080bbeb5b157` | `0e20d2c291853f196c68922a264bcd8471d75b68` |
| libbluray (release, includes libudfread 1.2.0) | `https://download.videolan.org/pub/videolan/libbluray/1.4.0/libbluray-1.4.0.tar.xz` | `77937baf07eadda4b2b311cf3af4c50269d2ea3165041f5843d96476c4c92777` | |
| libbluray (tag, without libudfread) | `https://code.videolan.org/videolan/libbluray/-/archive/1.4.0/libbluray-1.4.0.tar.gz` | `0dc218f79435798a62da2a0510e0e921a3f7c1b140507df8e65f48d98046f024` | `9f07fbb2077be7a40b062bcf2463a9941c2a3b13` |
| libudfread | `https://download.videolan.org/pub/videolan/libudfread/libudfread-1.2.0.tar.xz` | `bb477cbd4cfbfc7787d9d05b71ee5e70430f5cfebf1297497f7e83547958050f` | |
| uchardet (release) | `https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz` | `e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0` | |
| uchardet (tag) | `https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v0.0.8/uchardet-v0.0.8.tar.gz` | `5aa402a1b5b1dbb8d81096f141ff1224e079f4d3a1db0f79ecca782756d3a416` | `ae6302a016088ad07177f86d417b20010053632b` |

Hosts outside `github.com` that these sources need: `download.savannah.gnu.org` (FreeType release tarball only; the GitHub mirror suffices), `download.videolan.org` and `code.videolan.org` (libbluray, libudfread) and `www.freedesktop.org` and `gitlab.freedesktop.org` (uchardet). When this was written, the pipeline's fetch allowlist (`FETCH_ALLOWED` in `engine/lucid.py`) named only `github.com` prefixes, and its reference-host list already included `code.videolan.org` and `gitlab.freedesktop.org` [vivid]. It now also names the libbluray and uchardet release folders on `download.videolan.org` and `www.freedesktop.org`.

---

## 6. Interim release names

The interim releases' names are not upstream refs [ci]. The four text libraries (FreeType, FriBidi, HarfBuzz, libunibreak) share one release named after libass 0.17.4; each carries its own version (3.1 to 3.4). libplacebo's release, `7.351.0-2512`, adds a suffix to upstream v7.351.0. lcms2's `2.17.0` and shaderc's `2025.5.0` are upstream `lcms2.17` and `v2025.5`. uavs3d's `1.2.1-fix` (3.9) and uchardet's `0.0.8-xcode` (3.11) mark build-configuration rebuilds. Section 3 gives each library's upstream ref.

---

## 7. Not determined

- The exact clang version. The objects carry no producer string or debug info. Xcode 15.4 is inferred from SDK 17.5 and the CI's Xcode selection.
- Whether MoltenVK 1.4.1 compiles against SDK 26 with `MVK_XCODE_16` and `MVK_XCODE_26` predefined as 0 was not tested.
- That the build host's default pkg-config path supplied Homebrew's `.pc` files for the macOS SDK's zlib and libxml2, and Homebrew's cairo and GLib, is inferred. The run logs were not read. The observed facts are the resolved `Requires` lines, `hb-features.h` and the `-licucore` that the earlier facts record in FFmpeg's `libavformat.pc`.
- The `-O3` level of the meson and CMake builds comes from the configuration (`buildtype=release`, `CMAKE_BUILD_TYPE=Release`). It was not measured. That libunibreak is unoptimised was seen in its disassembly.
- Which static initialisers run in the shipped app is inferred from a count match (40 = 36 + 4). The app executable is stripped.
- Reachability (B) comes from symbol references and Vivid's option settings, not from runtime tracing. The old bridge's Swift sources were not read; the `vo` and `hwdec` values come from the engine spec.

## 8. Corrections to `lucid-engine-build-facts.md`

- 2.8 MoltenVK: the patch's effect is that Apple GPU family 9 is never detected on any platform, iOS included, not only on tvOS and visionOS (3.7).
- 2.4 HarfBuzz: `hb-features.h` defines `HB_HAS_CAIRO` and `HB_HAS_GOBJECT` (host-detected). `libharfbuzz.a` itself still has no cairo or GObject code.
- 2.4 libunibreak: the archive is unoptimised and has assertions on.
- 2.11 uavs3d: `0e20d2c2` is the lightweight tag `1.2`. Its GitHub release was published after today's build. The `.pc` version `1.2.1` and the commit id printed by `uavs3d_create` come from the third-party build repository that contained the build directory, not from uavs3d. The bit depth is confirmed as 10 in the binary.
- 2.5 libplacebo: the compiled-in version string is `v7.351.0 (v7.351.0-dirty)`. The applied change is upstream commit `a22f0dff`.
