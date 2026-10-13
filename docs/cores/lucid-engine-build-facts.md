# Lucid Engine build configuration: facts for an independent rebuild

Dirty-side fact sheet. It records what Vivid consumes today and how each binary in the dependency graph is configured, so that a clean-room engineer can produce equivalent binaries with their own scripts. It states values and observed outputs only. It contains no build-script code and does not describe how edde746's or mpvkit's scripts are organised.

Prepared 13 October 2026 from the pinned package `edde746/mpv-build` at `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6`.

## 0. Evidence and conventions

Every fact carries one of these tags:

| Tag | Meaning |
| --- | --- |
| [bin] | Observed in the binaries SwiftPM resolves for that pin. SwiftPM's `workspace-state.json` records the URL and checksum of all 25 resolved artefacts, and these match `Package.swift` at the pin. Evidence comes from `otool`, `nm`, `lipo`, `strings`, shipped `config.h` files and `Info.plist` files. |
| [cfg] | Stated as a configuration value (option, flag or URL) in the build configuration at the commit that produced the published asset. |
| [up] | Taken from upstream source at the stated tag or commit. |
| [ci] | Taken from GitHub Actions run metadata or logs. |
| [vivid] | Taken from the Vivid repository (main, or the branch named). |

Other conventions:
- Paths inside build machines are written as `<work>` and never reproduced.
- "Device" means `iphoneos` or `appletvos`. "Simulator" means `iphonesimulator` or `appletvsimulator`.
- Not inspected, by instruction: `iosApp/iosApp/Playback/MPV/MpvPlayerCoreBase.swift`, `MpvPlayerCore.swift` and `ExternalDisplayManager.swift`.

---

## 1. What Vivid consumes

### 1.1 Package pin and identity [vivid]

- `iosApp/project-ios.yml` (target `Vivid`, iOS) and `iosApp/project.yml` (target `VividTV`, tvOS) declare the package key `MPVKit`:
  - URL `https://github.com/edde746/mpv-build`
  - revision `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6`
  - each app target depends on `package: MPVKit, product: MPVKit`
- The extensions do not link the engine: `VividDownloadsActivity` (iOS) and `VividTVTopShelf` (tvOS).
- `iosApp/Vivid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins the engine with identity `mpv-build`, kind `remoteSourceControl`, the same URL and revision. SwiftPM derives the identity from the last URL path component, so a new repository name changes it.
- The identity is also the folder name of the resolved binaries: `<DerivedData>/SourcePackages/artifacts/mpv-build/<Target>/<Target>.xcframework`. `scripts/release/use-patched-libmpv.sh` and `.github/workflows/mpv-audio-driver.yml` both depend on that path (see 1.8).

### 1.2 Package manifest at the pin [cfg]

- Swift tools version 5.8. Package name `MPVKit`. Platforms macOS 12, iOS 15 and tvOS 15.
- There is one library product, `MPVKit`, built from the target `_MPVKit`, with automatic linkage.
- There are two source targets. Each contains only `dummy.c` and `include/dummy.h` and exists to carry dependencies and linker settings.

`_MPVKit` (path `Sources/_MPVKit`):
- Dependencies: `Libmpv`, `_FFmpeg`, `Libuchardet`, `Libbluray`, and `Libluajit` (macOS only).
- Linked frameworks: AVFoundation, CoreImage, CoreMedia, CoreVideo, Metal, QuartzCore, CoreAudio, AppKit (macOS only) and UIKit (iOS and tvOS only).

`_FFmpeg` (path `Sources/_FFmpeg`):
- Dependencies: `Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale`, `Libssl`, `Libcrypto`, `Libass`, `Libfreetype`, `Libfribidi`, `Libharfbuzz`, `MoltenVK`, `Libshaderc_combined`, `lcms2`, `Libplacebo`, `Libdovi`, `Libunibreak`, `Libdav1d` and `Libuavs3d`.
- Linked frameworks: AudioToolbox, CoreVideo, CoreFoundation, CoreMedia, Metal, Security and VideoToolbox.
- Linked libraries: `bz2`, `iconv`, `expat`, `resolv`, `xml2`, `z` and `c++`.

The 25 binary targets (URL and SwiftPM checksum) are below. The checksum is the SHA-256 of the zip, and it equals GitHub's asset digest.

| Binary target | Published asset | Checksum |
| --- | --- | --- |
| Libmpv | edde746/mpv-build `binaries-apple` / `Libmpv-4016569ef4b2.xcframework.zip` | `9b1ae5cebb28960335b6f2764c6e23ff414567b781705c006e073d756062f403` |
| Libavcodec | edde746/mpv-build `binaries-apple` / `Libavcodec-c04b889c6bf7.xcframework.zip` | `dde8d31d9cffe811cf880b2280e9d77d308cc4d8796e6c4d2da60c821f16641d` |
| Libavdevice | same release, `Libavdevice-c04b889c6bf7.xcframework.zip` | `75d5092f471d4aa7a84214d1755893fd5d25f6d5969f90853c6889025c967cd4` |
| Libavfilter | same, `Libavfilter-c04b889c6bf7` | `408c744a5b5fc071fd17b7f733d4d07e0d9a5355221a00f6d5ddecb339842d49` |
| Libavformat | same, `Libavformat-c04b889c6bf7` | `ed734294892b1c70c53929a03ba186021108a40e3725945a9561fc28e093c67d` |
| Libavutil | same, `Libavutil-c04b889c6bf7` | `30364135be0d70ef33d732c082e99a5a648ea47b39ae2e0718588a5cb679ae1d` |
| Libswresample | same, `Libswresample-c04b889c6bf7` | `7fd1148782093afbc9aa0409406b9054ee0d2e5adc0c0ec50b078a2e568583b3` |
| Libswscale | same, `Libswscale-c04b889c6bf7` | `3fe8789f0c297dc84e0064b84e4697d44650defbbaff5d13eeb8b112f93996a3` |
| Libass | same, `Libass-dcf94c1d6ebe` | `7f4aa426e94193b8b5f6a7edd0d6033e14a1b61ecba28e4631b4cadad610e414` |
| Libunibreak | mpvkit/libass-build `0.17.4` / `Libunibreak.xcframework.zip` | `001087c0e927ae00f604422b539898b81eb77230ea7700597b70393cd51e946c` |
| Libfreetype | mpvkit/libass-build `0.17.4` | `f2840aba1ce35e51c0595557eee82c908dac8e32108ecc0661301c06061e051c` |
| Libfribidi | mpvkit/libass-build `0.17.4` | `4a55513792ef7a17893875f74cc84c56f3657e8768c07a7a96f563a11dc4b743` |
| Libharfbuzz | mpvkit/libass-build `0.17.4` | `91558d8497d9d97bc11eeef8b744d104315893bfee8f17483d8002e14565f84b` |
| Libbluray | mpvkit/libbluray-build `1.4.0` | `bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d` |
| Libcrypto | mpvkit/openssl-build `3.3.5` | `593283be2a90f7fd66f6e6ed331b2f099cf403e0926fe3b4ac09a7062b793965` |
| Libssl | mpvkit/openssl-build `3.3.5` | `ff5ffd43d015d7285fd37e4a3145b25cbd8d2842740bd629a711c299a20e226a` |
| Libuavs3d | mpvkit/libuavs3d-build `1.2.1-fix` | `bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789` |
| Libdovi | mpvkit/libdovi-build `3.3.2` | `e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d` |
| MoltenVK | mpvkit/moltenvk-build `1.4.1` | `9bd1ca1e4563bacd25d6e55d37b10341d50b2601bc2684bc332188e79daa2b79` |
| Libshaderc_combined | mpvkit/libshaderc-build `2025.5.0` | `758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b` |
| lcms2 | mpvkit/lcms2-build `2.17.0` | `dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982` |
| Libplacebo | mpvkit/libplacebo-build `7.351.0-2512` | `3b2bd57b82549566963effadf0891a141448d9f89c7d48fca0b8f823b854bac6` |
| Libdav1d | edde746/libdav1d-build `1.5.3-neon` (pre-release) | `7965ecf274af5448fa830bc1fec4e78257cf1d7509ed1cd95e32023b7bdff965` |
| Libuchardet | mpvkit/libuchardet-build `0.0.8-xcode` | `503202caa0dafb6996b2443f53408a713b49f6c2d4a26d7856fd6143513a50d7` |
| Libluajit | mpvkit/libluajit-build `2.1.0-xcode` (macOS only in the product) | `8e76f267ee100ff5f3bbde7641b2240566df722241cdf8e135be7ef3d29e237a` |

Full asset URL forms:
- edde746: `https://github.com/edde746/mpv-build/releases/download/binaries-apple/<asset>`
- mpvkit: `https://github.com/mpvkit/<repo>/releases/download/<tag>/<Name>.xcframework.zip`
- edde746 dav1d: `https://github.com/edde746/libdav1d-build/releases/download/1.5.3-neon/Libdav1d.xcframework.zip`

### 1.3 Modules and symbols Vivid uses [vivid]

- Swift files inspected on `main` import exactly one engine module, `Libmpv`, in three files: `iosApp/iosApp/Playback/MPV/VividMPVPlayer.swift`, `VividManagedStreamProtocol.swift` and `LucidSubtitleInventory.swift`. On `origin/fix/lgpl-media-engine`, `LucidTLS.swift` also imports `Libmpv`.
- `LucidTLS.swift` (LGPL branch) reaches the FFmpeg C symbol `avformat_configuration` through `@_silgen_name`, not through a module. Its comment records that `import Libavformat` fails today. The packaged `Libavutil` module's umbrella includes `hwcontext_amf.h`, which needs AMD AMF SDK headers, so the module does not build. That header and `hwcontext_drm.h`, `hwcontext_mediacodec.h` and `hwcontext_oh.h` are not in the exclusion list (see 4.3). The new `Libavformat` must therefore export `_avformat_configuration`.
- These mpv C API names are used in the inspected files:
  - functions: `mpv_create`, `mpv_initialize`, `mpv_set_option`, `mpv_set_option_string`, `mpv_get_property`, `mpv_command_async`, `mpv_wait_event`, `mpv_terminate_destroy`, `mpv_free_node_contents`, `mpv_stream_cb_add_ro`
  - types: `mpv_node`, `mpv_node_list`, `mpv_stream_cb_open_ro_fn`
  - constants: `MPV_FORMAT_NODE`, `MPV_FORMAT_STRING`, `MPV_FORMAT_NODE_ARRAY`, `MPV_EVENT_FILE_LOADED`, `MPV_EVENT_END_FILE`, `MPV_ERROR_LOADING_FAILED`, `MPV_ERROR_UNSUPPORTED`, `MPV_ERROR_GENERIC`
- So the headers `mpv/client.h` and `mpv/stream_cb.h` are required at minimum. `Libmpv` ships `mpv/client.h`, `mpv/render.h`, `mpv/render_gl.h` and `mpv/stream_cb.h`, with `MPV_CLIENT_API_VERSION` = `MPV_MAKE_VERSION(2, 5)` [bin].
- Unknown: whether the three files I could not open import other engine modules. Keep all 25 module names and the product name `MPVKit` until the caller confirms.

### 1.4 Slices present and slices Vivid uses [bin]

| Slice set | xcframeworks |
| --- | --- |
| ios-arm64, ios-arm64_x86_64-maccatalyst, ios-arm64_x86_64-simulator, macos-arm64_x86_64, tvos-arm64_arm64e, tvos-arm64_x86_64-simulator | Libmpv, Libass, the seven FFmpeg ones |
| the above plus xros-arm64, xros-arm64-simulator | Libbluray, Libcrypto, Libssl, Libdav1d, Libdovi, Libfreetype, Libfribidi, Libharfbuzz, Libplacebo, Libshaderc_combined, Libuavs3d, Libuchardet, Libunibreak, lcms2 |
| the above but xros-arm64_x86_64-simulator | MoltenVK |
| no Catalyst slice; has xros-arm64, xros-arm64-simulator | Libluajit |

Architectures per slice: `ios-arm64` holds arm64; `ios-arm64_x86_64-simulator` and `tvos-arm64_x86_64-simulator` hold arm64 and x86_64; `tvos-arm64_arm64e` holds arm64 and arm64e.

What Vivid actually links [vivid] [bin]:
- `SUPPORTED_PLATFORMS` is `iphoneos iphonesimulator` for `Vivid` and `appletvos appletvsimulator` for `VividTV`. There is no Catalyst (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`), no visionOS and no macOS.
- `project-common.yml` sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` and `EXCLUDED_ARCHS[sdk=appletvsimulator*] = x86_64`.
- Latest local archives: `VividTV 0.14.3 (70)` and `Vivid 0.14.3 (75)`. Both executables are `arm64` only (no arm64e), built with SDK 27.0. VividTV has `minos 26.0`; Vivid has `minos 18.0`.
- Debug simulator products are arm64 only.
- Needed slices are therefore `ios-arm64` (arm64), `ios-arm64_x86_64-simulator` (arm64 used) and `tvos-arm64_arm64e` (arm64 used; arm64e present but never linked). For the tvOS simulator slice, `tvos-arm64_x86_64-simulator` (arm64 used).
- Not needed by Vivid: x86_64, arm64e, Catalyst, macOS and visionOS. `Libluajit` is not part of either app.

### 1.5 Deployment targets and SDKs

- App deployment targets [vivid]: iOS `18.0`, tvOS `26.0`. The package declares iOS 15 and tvOS 15 [cfg].

Per-library `LC_BUILD_VERSION` [bin], aggregated over every archive member:

| Library | minos (device arm64 / arm64e / simulator arm64 / simulator x86_64) | SDK |
| --- | --- | --- |
| Libmpv, Libass, seven FFmpeg | 14.0 everywhere | 26.5 |
| Libplacebo, lcms2, Libshaderc_combined, Libdav1d, Libbluray | 14.0 everywhere | 17.5 |
| MoltenVK | iOS 14.0; tvOS 14.5 (device and simulator) | 17.5 |
| Libuavs3d | 15.0 everywhere | 17.5 |
| Libfreetype, Libfribidi, Libharfbuzz, Libunibreak, Libuchardet, Libssl, Libcrypto | device arm64 13.0; arm64e and simulator arm64 14.0; simulator x86_64 13.0 | 17.5 |
| Libdovi (Rust) | device and simulator x86_64: `LC_VERSION_MIN_IPHONEOS`/`LC_VERSION_MIN_TVOS` 10.0; simulator arm64: `LC_BUILD_VERSION` 14.0 | n/a |
| Libluajit | 17.5 | 17.5 |

Toolchains [ci] [bin]:
- edde746-built (Libmpv, Libass, FFmpeg): GitHub runner `macos-26`, `/Applications/Xcode_26.6.app`, SDKs `iPhoneOS26.5` and `AppleTVOS26.5`. `CC_IDENT` is "Apple clang version 21.0.0 (clang-2100.1.1.101)". meson 1.4.2 from pip.
- mpvkit-built prebuilts: runner `macos-14`, `xcode-select -s /Applications/Xcode_15.4.app` (SDK 17.5), meson 1.4.2. dav1d and uavs3d go through the shared `mpvkit/BuildShared` workflow, which selects the same runner and Xcode.
- The local Mac has Xcode 27.0 (27A266a). The archives above were built with SDK 27.0.

### 1.6 Form of every framework [bin]

- Every framework binary is a static `ar` archive (fat via `lipo`). None is dynamic.
- MoltenVK is a library-type xcframework (`libMoltenVK.a`, no headers, no module).
- Every archive has a symbol table. Libmpv, Libdovi, Libharfbuzz, Libshaderc_combined and Libuchardet carry an unsorted `__.SYMDEF`, which `file` reports as `current ar archive`. The others carry `__.SYMDEF SORTED`, reported as `current ar archive random library`.
- Section 4 gives the bundle layout, Info.plist and module map.

### 1.7 How the engine ends up in the app [bin]

- The engine code is linked statically into the app executable. `strings` on `VividTV` shows mpv's `Configuration: -Dlibmpv=true ...`, and `nm` shows the engine symbols.
- The archive's `.app/Frameworks/` also holds 23 framework bundles: every framework-type target except Libluajit and MoltenVK. Each contains:
  - `Info.plist`, copied from the package (`MinimumOSVersion` 100.0)
  - `_CodeSignature`
  - a ~51 KB Mach-O dylib with no symbols, `LC_ID_DYLIB @rpath/<Name>.framework/<Name>`, `minos 100.0`, `sdk 27.0`, linking only `libSystem`
- The app executable has no load command for these dylibs. That these placeholders come from Xcode's embedding of static framework bundles is an inference; nothing in the Vivid repository creates them.
- App Store Connect reports an embedded bundle whose `MinimumOSVersion` it rejects as error ITMS-90208 (invalid bundle). Today's value of 100.0 avoids it. The exact rule App Store Connect applies was not verified here; see open question 5.
- Load commands of both apps include OpenGLES, CoreGraphics, CoreText, IOSurface and Foundation. The package does not declare any of them, but the archives need them (see 5.3). OpenGLES is not imported by any Vivid Swift file I could inspect, so where its link comes from is not established.
- Current shipped baseline: both archives contain the audio-driver marker string from Vivid's mpv patch. `VividTV (70)` contains `-Dgpl=false` and no `-Dgpl=true`; `Vivid (75)` contains `-Dgpl=true`. Shipped device builds therefore link Libmpv (and, on tvOS, the LGPL FFmpeg) slices that `use-patched-libmpv.sh` substituted from the audio-driver workflow, not the package's stock slices.

### 1.8 Vivid files that depend on the current names [vivid]

| File | Dependency |
| --- | --- |
| `iosApp/project-ios.yml`, `iosApp/project.yml` | package key `MPVKit`, URL, revision, product `MPVKit` |
| `Package.resolved` | identity `mpv-build`, URL, revision |
| `VividMPVPlayer.swift`, `VividManagedStreamProtocol.swift`, `LucidSubtitleInventory.swift` (and `LucidTLS.swift` on the LGPL branch) | `import Libmpv` |
| `LucidTLS.swift` (LGPL branch) | C symbol `avformat_configuration` |
| `scripts/release/use-patched-libmpv.sh` | path `SourcePackages/artifacts/mpv-build/<Name>/<Name>.xcframework/<slice>/<Name>.framework`; slice names `tvos-arm64_arm64e` and `ios-arm64`; framework names (Libmpv on main; Libmpv plus the seven FFmpeg frameworks on the LGPL branch); marker strings `-Dgpl=false`, `LGPL version 2.1 or later` and `GPL version 3 or later` |
| `.github/workflows/mpv-audio-driver.yml` | checks out `edde746/mpv-build` at the pin, applies Vivid patches, runs `make build use-prebuilt libs=... platform=...`, uploads `Libmpv*.zip`, `Libav*.zip` and `Libsw*.zip` |
| `.github/workflows/mpv-experiment.yml` | mentions the package (not inspected in detail) |
| `THIRD_PARTY_NOTICES.md`, `docs/cores/player-engine.md`, `iosApp/Resources/OpenSourceLicenses/*` (`licences.json`, `FFmpeg-GPL-3.0-or-later.txt`, `mpv-GPL-2.0-or-later.txt`, `OpenSSL-Apache-2.0.txt` and the others) | names, versions, sources and licences of every component |

---

## 2. Library by library

### 2.0 Common cross-compilation settings

These apply to all libraries built by mpv-build (FFmpeg, libass, mpv) and, unless a subsection says otherwise, to every mpvkit-built prebuilt [cfg]. Values for the four Vivid platforms:

| Platform | SDK (`xcrun --sdk`) | `-target` triple (arm64 / x86_64) | Version-min flag | meson `subsystem` | CMake `CMAKE_SYSTEM_NAME` | autotools `--host` |
| --- | --- | --- | --- | --- | --- | --- |
| iOS device | `iphoneos` | `arm64-apple-ios<MIN>` | `-mios-version-min=<MIN>` | `ios` | `iOS` | `arm64-ios-darwin` |
| iOS simulator | `iphonesimulator` | `arm64-apple-ios<MIN>-simulator` / `x86_64-apple-ios<MIN>-simulator` | `-mios-simulator-version-min=<MIN>` | `ios-simulator` | `iOS` | `arm64-ios-darwin` / `x86_64-ios-darwin` |
| tvOS device | `appletvos` | `arm64-apple-tvos<MIN>` (also for the arm64e slice, together with `-arch arm64e`) | `-mtvos-version-min=<MIN>` | `tvos` | `tvOS` | `arm64-tvos-darwin` |
| tvOS simulator | `appletvsimulator` | `arm64-apple-tvos<MIN>-simulator` / `x86_64-apple-tvos<MIN>-simulator` | `-mtvos-simulator-version-min=<MIN>` | `tvos-simulator` | `tvOS` | `arm64-tvos-darwin` / `x86_64-tvos-darwin` |

`<MIN>` by producer:
- edde746 (mpv, FFmpeg, libass) and mpvkit repos that use 14.0 (lcms2, libbluray, libplacebo, moltenvk-build wrapper, shaderc; dav1d via BuildShared `f5a3600`): 14.0
- libass-build (unibreak, freetype, fribidi, harfbuzz), openssl-build, libdovi-build, uchardet-build, luajit-build: 13.0
- uavs3d (BuildShared `794a8f5`): 15.0

Architectures: iOS device arm64; tvOS device arm64 and arm64e; simulators arm64 and x86_64.

Environment for every compile:
- `CC=/usr/bin/clang`, `CXX=/usr/bin/clang++`
- `CFLAGS = CPPFLAGS = CXXFLAGS = ASMFLAGS =` `-arch <arch> -isysroot <SDK path> -target <triple> <version-min flag>`, plus `-DHAVE_FORK=0` on tvOS device and tvOS simulator
- `LDFLAGS =` `-lc++ -arch <arch> -isysroot <SDK path> -target <triple> <version-min flag>`
- `PKG_CONFIG_LIBDIR`: the `lib/pkgconfig` directory of each dependency for the same platform and arch, then the host's default pkg-config search path. libxml2 is found through the host default path (see 2.2).
- `PATH`: the python.org framework `bin` directory first (`/Library/Frameworks/Python.framework/Versions/Current/bin`), then Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), then the system directories.

Meson cross-compilation values (meson's own cross-file keys):
- Host machine: system `darwin`, kernel `xnu`, endianness little. `cpu_family` is `aarch64` for arm64 and arm64e and `x86_64` for x86_64; `cpu` is `arm64` or `x86_64`. `subsystem` is as in the table above.
- Compilers: `/usr/bin/clang` for C and Objective-C, `/usr/bin/clang++` for C++ and Objective-C++. `ar` and `strip` are the SDK's own, located with `xcrun --sdk <sdk> --find`. pkg-config is the host `pkg-config`.
- Built-in options: static libraries only, release build type, install prefix per platform and arch. The compile arguments for every language are the CFLAGS above, and the link arguments are the LDFLAGS above.
- mpv and libass are built with `b_ndebug=true`. The prebuilt libraries are not.

CMake projects (mpvkit) receive:
- `-DCMAKE_VERBOSE_MAKEFILE=0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT=<sdk> -DCMAKE_OSX_ARCHITECTURES=<arch> -DCMAKE_SYSTEM_NAME=<iOS|tvOS> -DCMAKE_SYSTEM_PROCESSOR=<arch> -DCMAKE_INSTALL_PREFIX=<dir> -DBUILD_SHARED_LIBS=0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5`
- plus the per-library options below

Autotools projects receive `--prefix=<dir>` plus the per-library options. Builds use `make -j8`.

Exceptions to these settings:
- MoltenVK is built through MoltenVK's own `make` targets and Xcode project. None of the environment variables above is passed, so its deployment targets (iOS 14.0, tvOS 14.5) come from MoltenVK's own project settings.
- LuaJIT receives only `TARGET_FLAGS="-arch <arch> -isysroot <sdk>"` and no version-min flag, which is why its objects carry `minos 17.5` (the SDK version).
- libdovi is compiled by `cargo` for Rust targets (see 2.7). Its device and x86_64 objects carry the Rust targets' default minimums, not the C flags above.

### 2.1 mpv (libmpv)

- Upstream: `https://github.com/mpv-player/mpv`, tag `v0.41.0`, commit `41f6a645068483470267271e1d09966ca3b9f413` [cfg].
- Licence: GPL-2.0-or-later as built today (`-Dgpl=true`); LGPL-2.1-or-later with `-Dgpl=false` [up].
- Source today: built from source by edde746/mpv-build (upstream plus edde746's Apple patch series). Published as `Libmpv-4016569ef4b2.xcframework.zip`, with per-platform zips `libmpv-all-4016569ef4b2-<platform>.zip`. The tvOS zip's SHA-256 is `9ab90c831102d38b11c17b4a801fc79e93e7240ef9e42f03e9578e4dcf22dc25` [ci].
- Build system: meson, using the 2.0 cross file. Output `libmpv.a`, installed headers `include/mpv/{client,render,render_gl,stream_cb}.h` and `mpv.pc`.
- Version string in the binary: `mpv v0.41.0-dirty` [bin].

Meson options for iOS and tvOS, identical on all four platforms and both archs. This is the string embedded in the binary [bin] [cfg]:

```
-Dlibmpv=true -Dgl=enabled -Dplain-gl=enabled -Diconv=enabled -Duchardet=enabled -Dvulkan=enabled -Dmoltenvk=enabled -Djavascript=disabled -Dzimg=disabled -Djpeg=disabled -Dvapoursynth=disabled -Drubberband=disabled -Dgpl=true -Dlibbluray=enabled -Dcplayer=false -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=enabled -Dswift-build=disabled -Daudiounit=enabled -Davfoundation=enabled -Dvo-avfoundation=enabled -Dlua=disabled -Dios-gl=enabled
```

- Option origin [up]: every option above exists in upstream mpv 0.41.0 `meson.options` except `moltenvk` and `vo-avfoundation`. Those two exist only once edde746's patches `0001-player-add-moltenvk-context.patch` and `0004-avfoundation-video-output.patch` are applied. Upstream meson rejects them otherwise.
- `-Dlibbluray=enabled` requires libbluray's headers and `.pc` file for the target platform and arch at configure time. `-Dcplayer=false` means no mpv executable is built for iOS or tvOS.
- The macOS and Catalyst variants use different options. They are not needed by Vivid and are omitted here.

Resulting enabled feature list. Identical on every slice; use it as the acceptance check [bin]:

```
audiounit avfoundation bsd-fstatfs build-date cplugins darwin ffmpeg gl glob glob-posix gpl iconv ios-gl lcms2 libass libavdevice libbluray libdl libplacebo mac-thread-name macos-10-15-4-features macos-11-3-features macos-11-features macos-12-features moltenvk posix posix-shm uchardet vector videotoolbox-pl vo-avfoundation vulkan zlib
```

- Not enabled, among others: `shaderc`, `spirv-cross`, `libarchive`, `dvdnav`, `cdda`, `coreaudio`, `cocoa`, `egl`, `lua`, `javascript`, `zimg`, `jpeg`, `rubberband`, `vapoursynth`.
- `build-date` is on (meson default), so the binary embeds a build timestamp.
- Dependencies through pkg-config, from the shipped `mpv.pc` `Requires` [bin]: `libass >= 0.12.2, libavcodec >= 60.31.102, libavfilter >= 9.12.100, libavformat >= 60.16.100, libavutil >= 58.29.100, libplacebo >= 6.338.2, libswresample >= 4.12.100, libswscale >= 7.5.100, lcms2 >= 2.6, libavdevice >= 60.3.100, libbluray >= 0.5.0, uchardet, zlib, vulkan >= 1.3.238`.
- `mpv.pc` `Libs` on tvOS, with repeated entries removed: `-lmpv -liconv -lm -framework Foundation -framework AudioToolbox -framework CoreMedia -framework AVFoundation -framework CoreVideo -framework CoreImage -framework QuartzCore -framework Metal -framework UIKit`.
- No source edits outside the patch series.

### 2.2 FFmpeg

- Upstream: `https://github.com/FFmpeg/FFmpeg`, tag `n8.0.1`, commit `894da5ca7d742e4429ffb2af534fcda0103ef593`. `FFMPEG_VERSION "n8.0.1"` [cfg] [bin].
- Library versions from the shipped `.pc` files: avcodec 62.11.100, avformat 62.3.100, avutil 60.8.100, avfilter 11.4.100, swresample 6.1.100, swscale 9.1.100.
- Licence: LGPL-2.1-or-later by default; "GPL version 3 or later" as built today (`FFMPEG_LICENSE`) [bin].
- Source today: built from source by edde746/mpv-build (upstream plus edde746's Apple FFmpeg series). Published as `Lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}-c04b889c6bf7.xcframework.zip`, with per-platform zips `FFmpeg-all-c04b889c6bf7-<platform>.zip`. The tvOS zip's SHA-256 is `3b183cf45518bb3cfa10e7cbe7e8429966d1ba27f3eb508671f75d2ed550d9e1`.
- Build system: `./configure` (autotools-style), then `make -j8` and `make -j8 install`. Output is static `lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}.a`. The compiler is the configure default (`gcc` on the PATH, which is Apple clang); flags reach configure through the environment variables in 2.0. No `--cc`, `--sysroot` or `--extra-cflags` is passed.
- Extra environment for FFmpeg only: `-I<libdovi>/include` in the C flags, and `-L<libdovi>/lib -ldovi` in `LDFLAGS`.
- Host tools: `nasm` (Homebrew). `sdl2` is also present on the build host but is only used for the macOS `ffplay` build.

Configure line for device arm64, device arm64e and simulator arm64, identical on iOS and tvOS. This is the embedded `FFMPEG_CONFIGURATION` with `--prefix` removed [bin]:

```
--disable-armv5te --disable-armv6 --disable-armv6t2 --disable-bzlib --disable-gray --disable-iconv --disable-linux-perf --disable-shared --disable-small --disable-symver --disable-xlib --enable-cross-compile --enable-libxml2 --enable-optimizations --enable-pic --enable-runtime-cpudetect --enable-static --enable-thumb --enable-version3 --pkg-config-flags=--static --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages --enable-avcodec --enable-avformat --enable-avutil --enable-network --enable-swresample --enable-swscale --disable-securetransport --disable-gnutls --disable-libtls --disable-mbedtls --disable-devices --disable-outdevs --disable-indevs --disable-d3d11va --disable-d3d12va --disable-dxva2 --disable-vaapi --disable-vdpau --enable-muxers --enable-encoders --enable-protocols --enable-demuxers --enable-bsfs --enable-decoders --disable-filters --enable-filter=crop --enable-filter=aformat --enable-filter=amix --enable-filter=anull --enable-filter=aresample --enable-filter=areverse --enable-filter=asetrate --enable-filter=atempo --enable-filter=atrim --enable-filter=bwdif --enable-filter=delogo --enable-filter=equalizer --enable-filter=estdif --enable-filter=firequalizer --enable-filter=format --enable-filter=fps --enable-filter=hflip --enable-filter=hwdownload --enable-filter=hwmap --enable-filter=hwupload --enable-filter=idet --enable-filter=lenscorrection --enable-filter='lut*' --enable-filter=negate --enable-filter=null --enable-filter=overlay --enable-filter=palettegen --enable-filter=paletteuse --enable-filter=pan --enable-filter=rotate --enable-filter=scale --enable-filter=setpts --enable-filter=superequalizer --enable-filter=transpose --enable-filter=trim --enable-filter=vflip --enable-filter=volume --enable-filter=loudnorm --enable-filter=w3fdif --enable-filter=yadif --enable-filter=avgblur_vulkan --enable-filter=blend_vulkan --enable-filter=bwdif_vulkan --enable-filter=chromaber_vulkan --enable-filter=flip_vulkan --enable-filter=gblur_vulkan --enable-filter=hflip_vulkan --enable-filter=nlmeans_vulkan --enable-filter=overlay_vulkan --enable-filter=vflip_vulkan --enable-filter=xfade_vulkan --disable-debug --enable-stripping --enable-optimizations --enable-gpl --disable-large-tests --ignore-tests=TESTS --arch=aarch64 --target-os=darwin --enable-neon --enable-asm --disable-programs --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --enable-libass --enable-filter=ass --enable-filter=subtitles --enable-vulkan --enable-libshaderc --enable-lcms2 --enable-libplacebo --enable-filter=libplacebo --enable-libdav1d --enable-decoder=libdav1d --enable-libuavs3d --enable-decoder=libuavs3d --enable-openssl
```

- Simulator x86_64 differs only in `--arch=x86_64 --disable-neon --disable-asm` instead of `--arch=aarch64 --enable-neon --enable-asm` [bin].
- Each `--enable-lib*`, `--enable-vulkan`, `--enable-lcms2` and `--enable-openssl` flag requires that dependency's headers and `.pc` file for the target platform and arch at configure time. The paired `--enable-filter=` and `--enable-decoder=` flags enable the components that use it.
- The macOS host variant adds `--enable-ffplay --enable-sdl2` and a few extra filters; not relevant to Vivid.

Resulting `CONFIG_*` state, identical on every iOS and tvOS slice [bin]:
- External and autodetected libraries on: `avfoundation coreimage metal zlib lcms2 libass libdav1d libfreetype libfribidi libharfbuzz libplacebo libshaderc libuavs3d libxml2 openssl audiotoolbox videotoolbox vulkan`.
- Off: `securetransport`, `bzlib`, `iconv`, `lzma`, `sdl2`, `opengl`, `opencl`, `libglslang`, `appkit`, `mediafoundation`, `libdrm`.
- `CONFIG_GPL 1`, `CONFIG_VERSION3 1`, `CONFIG_NETWORK 1`.
- Components enabled, by count: 519 decoders, 190 encoders, 358 demuxers, 183 muxers, 64 parsers, 48 bitstream filters, 15 hwaccels, 41 protocols, 64 filters (including buffer sources and sinks), 0 input and 0 output devices. The component sets are identical on all seven arch slices. Full lists are in Appendix A.
- hwaccels: `av1_videotoolbox av1_vulkan ffv1_vulkan h263_videotoolbox h264_videotoolbox h264_vulkan hevc_videotoolbox hevc_vulkan mpeg1_videotoolbox mpeg2_videotoolbox mpeg4_videotoolbox prores_raw_vulkan prores_videotoolbox vp9_videotoolbox vp9_vulkan`.
- `--enable-libxml2` is what enables the `dash` and `imf` demuxers [up].

Link flags recorded in the shipped tvOS `.pc` files [bin]:
- `libavcodec`: `-llcms2 -lm -ldav1d -luavs3d -lpthread -framework AudioToolbox -lshaderc_combined -lz -framework VideoToolbox -framework CoreFoundation -framework CoreMedia -framework CoreVideo`
- `libavformat`: `-lm -lxml2 -lz -lpthread -licucore -lssl -lcrypto`. The `-licucore` comes from the host-resolved `libxml-2.0`.
- `libavutil`: `-lm -lssl -lcrypto -framework VideoToolbox -pthread -framework CoreFoundation -framework CoreMedia -framework CoreVideo`
- `libavfilter`: `-lplacebo -ldl -lshaderc_combined -lMoltenVK -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit -llcms2 -ldovi -liconv -lass -framework CoreText -lfreetype -lz -lfribidi -lharfbuzz -lunibreak`

Source edits made outside the patch series [cfg] [bin]:
1. The compiled `libavcodec/videotoolbox.c` uses `kCVPixelBufferMetalCompatibilityKey` in place of both `kCVPixelBufferOpenGLESCompatibilityKey` (iOS branch) and `kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey` (macOS branch). In upstream n8.0.1 these are lines 821 and 823 inside `#if TARGET_OS_IPHONE`. No patch file makes this change. Binary check: Libavcodec references `_kCVPixelBufferMetalCompatibilityKey` and neither OpenGL key.
2. The frameworks' headers include these non-public files, which a normal `make install` does not install:
   - the build's own `config.h`, as `libavutil/config.h`, `libavcodec/config.h` and `libavformat/config.h`
   - from the source tree: `libavutil/{getenv_utf8.h, libm.h, thread.h, intmath.h, mem_internal.h, attributes_internal.h, internal.h}`, `libavcodec/mathops.h` and `libavformat/os_support.h`
   - The shipped `libavutil/internal.h` is byte-identical to upstream n8.0.1 [bin].
   - Only one `config.h` (the first arch's) is shipped per slice. Within one platform the copies differ only in the `FFMPEG_DATADIR`/`AVCONV_DATADIR` paths and per-arch values.
   - Whether anything consumes these internal headers is unknown (see 6).

Patch-series dependencies that change linking [cfg] [bin]:
- Libavcodec references libdovi (`dovi_convert_rpu_with_mode`, `dovi_data_free`, `dovi_parse_unspec62_nalu`, `dovi_rpu_free`, `dovi_rpu_get_error`, `dovi_write_unspec62_nalu`). The only Apple-series patch that includes `<libdovi/rpu_parser.h>` is `0003-videotoolbox-convert-dolby-vision-p7.patch`. Upstream n8.0.1 has no libdovi support. FFmpeg's libdovi dependency therefore exists only because of that patch.
- Without `0011-securetransport-disable-pem-import-for-catalyst.patch`, upstream Secure Transport on Catalyst is unchanged. Catalyst is not relevant to Vivid.

### 2.3 libass

- Upstream: `https://github.com/libass/libass`, tag `0.17.5` (annotated tag object `64ebcac7...`), commit `4a05d8127f525943ebf45fdc6497c9e665947f0d` [cfg] [up]. `LIBASS_VERSION 0x01705000` [bin].
- Licence: ISC.
- Source today: built from source by edde746/mpv-build, from upstream 0.17.5 plus three edde746 patches (`patches/libass/series.common`): fast blur, parser and rasteriser speedups, and threaded rendering with image pool and layout cache. Published as `Libass-dcf94c1d6ebe.xcframework.zip`; tvOS per-platform zip SHA-256 `0d224ea28fb21852d17984ec39589c960396d0d783e69d5934638cd30dc48045`.
- Build system: meson, using mpv-build's cross file (`b_ndebug=true`).

Meson options [cfg]:
- arm64 and arm64e: `-Dasm=enabled`. x86_64 simulator: `-Dasm=disabled`.
- All archs: `-Dlibunibreak=enabled -Dcoretext=enabled -Dfontconfig=disabled -Ddirectwrite=disabled -Dcheckasm=disabled -Dtest=disabled -Dprofile=disabled -Dcompare=disabled -Dfuzz=disabled`.
- All are upstream 0.17.5 options [up]. Patch 0003 adds a `threads` feature option, which is not passed and is left at its default.

Other facts:
- Dependencies, through pkg-config from the mpvkit libass-build prebuilts: `freetype2 >= 9.17.3, fribidi >= 0.19.7, harfbuzz >= 1.2.3, libunibreak >= 1.1`. Shipped `libass.pc` `Libs`: `-lass -lm -liconv -framework CoreText -framework CoreFoundation` [bin].
- The mpvkit libass-build `0.17.4` release also ships its own `Libass`, built from upstream 0.17.4 with `-Dasm=disabled` and otherwise the same options. Vivid does not use it.

### 2.4 FreeType, FriBidi, HarfBuzz, libunibreak

All four are prebuilt by `mpvkit/libass-build`, tag `0.17.4`:
- tag object `de7bcc21...`, commit `392f59146f1e043401126abb385678180f6ae8ef`
- assets produced by run 19487080817 at commit `a4d8ea60264c`, which differs from the tag commit only in `Package.swift`
- `-all.zip` digests: libfreetype `f0eec59e51f4137ba57afa849393ba4815c25418870b9511990bd4ebeacdbfaf`, libfribidi `e20ccc160ea2995f2ef2c5ee0ec50f307cbc10c371fb299b5df62546de07d59d`, libharfbuzz `c1f56b4f47b64b15e0be16a93703a6db484079878de16b6d598d22055d86f24c`, libunibreak `06f7e68102bb9f9f963b2517455dc543f438f7beccd002edcd63dcd1cbccd9a5`

The "0.17.4" in this tag is libass's version, not these libraries'. minos 13.0 applies (see 1.5).

| Library | Upstream, ref, commit | Licence | Build system and options [cfg] | Binary facts [bin] |
| --- | --- | --- | --- | --- |
| FreeType | `https://github.com/freetype/freetype` (mirror of freedesktop GitLab), `VER-2-12-1`, commit `e8ebfe988b5f57bfb9a3ecb13c70d9791bce9ecf` | FTL (or GPL-2.0), used under FTL | meson: `-Dzlib=enabled -Dharfbuzz=disabled -Dbzip2=disabled -Dmmap=disabled -Dpng=disabled -Dbrotli=disabled` | version 2.12.1; references system zlib (`inflate*`); headers under `freetype2/` |
| FriBidi | `https://github.com/fribidi/fribidi`, `v1.0.12`, commit `6428d8469e536bcbb6e12c7b79ba6659371c435a` | LGPL-2.1-or-later | meson: `-Ddeprecated=false -Ddocs=false -Dbin=false -Dtests=false` | `FRIBIDI_VERSION "1.0.12"` |
| HarfBuzz | `https://github.com/harfbuzz/harfbuzz`, `8.1.1`, commit `1d665c2b521512cdd56964138fc601debd1f1177` | MIT ("Old MIT") | meson: `-Dglib=disabled -Dfreetype=disabled -Ddocs=disabled -Dtests=disabled`; others default | `HB_VERSION_STRING "8.1.1"`; no CoreText, ICU, cairo, FreeType or GObject entry points; only pthread is needed from the system; headers include `hb-cairo.h` and `hb-gobject*.h` regardless |
| libunibreak | `https://github.com/adah1972/libunibreak`, tag `libunibreak_6_1`, commit `304585d8e2d63187507368d612c3d5fff1486368` | zlib | autotools: `--enable-static --disable-shared --disable-fast-install --disable-dependency-tracking --host=<see 2.0>` | 7 headers at framework root |

### 2.5 libplacebo (with fast_float, glad, jinja, markupsafe, Vulkan-Headers)

- Upstream: `https://github.com/haasn/libplacebo`, tag `v7.351.0` (tag object `98c1416e...`), commit `3188549fba13bbdf3a5a98de2a38c2e71f04e21e` [cfg] [up]. `PL_MAJOR_VER 7`, `PL_API_VER 351` [bin]. The `-2512` suffix in the release name is not part of the upstream ref; the build clones `v7.351.0`.
- Licence: LGPL-2.1-or-later.
- Submodules cloned recursively; gitlink pins at the tag [up]:
  - `3rdparty/fast_float` `1bf70101536d37fa9954cc4f03fd0903d045a9f3`
  - `3rdparty/glad` `73db193f853e2ee079bf3ca8a64aa2eaf6459043`
  - `3rdparty/jinja` `15206881c006c79667fe5154fe80c01c65410679`
  - `3rdparty/markupsafe` `28ace20b140d15c083e1cbc163ee6b7778ba098c`
  - `3rdparty/Vulkan-Headers` `cacef3039d277c448c89336290ec3937270b0996`
- Licences of these: fast_float MIT/Apache-2.0/BSL-1.0 (used under MIT); glad CC0-1.0 and Apache-2.0. jinja and markupsafe are build-time code generators only.
- Source today: prebuilt by `mpvkit/libplacebo-build` `7.351.0-2512`. Assets produced by run 20434622243 at `47a712b6eacd`, which differs from the tag commit `d9ff9205` only in `Package.swift`. `libplacebo-all.zip` SHA-256 `aa8574c1160deb17863a82258d9a4289e5a5413ca3a58f5e3b12bd25e5585919`.
- Build system: meson (mpvkit cross file, no `b_ndebug`). Python `jinja2` is needed on the host.
- Source edit: patch `00001-fix-python-3.14-build.patch`, the upstream fix in `src/vulkan/utils_gen.py` (`ET.parse(...).getroot()`).

Meson options [cfg]:
- `-Dopengl=enabled -Dvulkan=enabled -Dshaderc=enabled -Dlcms=enabled -Dxxhash=disabled -Dunwind=disabled -Dglslang=disabled -Dd3d11=disabled -Ddemos=false -Dtests=false -Ddovi=enabled -Dlibdovi=enabled`
- `-Ddovi=enabled -Dlibdovi=enabled` require libdovi's headers and library for the target platform and arch at configure time.
- libdovi include and link flags are also added to the C flags and `LDFLAGS`.

Dependencies at build time: lcms2, libdovi, shaderc and MoltenVK, taken from the mpvkit prebuilt `-all.zip` files of 2.6 to 2.9 at the same versions Vivid uses.

Vulkan headers [up]: libplacebo v7.351.0 compiles against its own `3rdparty/Vulkan-Headers` submodule whenever that directory exists. Gitlink `cacef303` is Vulkan-Headers `v1.4.310`. It also forces that submodule's `registry/vk.xml` for code generation. The `vulkan` pkg-config dependency (MoltenVK, 1.4.334) is used only to link `vkGetInstanceProcAddr` directly (`vk-proc-addr`, default auto), which gives `PL_HAVE_VK_PROC_ADDR 1`.

SPIRV-Cross (`https://github.com/KhronosGroup/SPIRV-Cross`, tag `vulkan-sdk-1.4.309.0`, commit `2c32b6bf86f3c4a5539aa1f0bacbd59fe61759cf`) is also compiled in the libplacebo-build run. It is not shipped, and Libplacebo has no SPIRV-Cross references [bin], so a rebuild does not need it.

Result [bin]:
- `config.h`: `PL_HAVE_DOVI 1`, `PL_HAVE_LIBDOVI 1`, `PL_HAVE_LCMS 1`, `PL_HAVE_OPENGL 1`, `PL_HAVE_GL_PROC_ADDR 1`, `PL_HAVE_SHADERC 1`, `PL_HAVE_VULKAN 1`, `PL_HAVE_VK_PROC_ADDR 1`; `PL_HAVE_D3D11`, `PL_HAVE_GLSLANG` and `PL_HAVE_XXHASH` are undefined.
- `libplacebo.pc`: `Requires: shaderc >= 2019.1, vulkan, lcms2 >= 2.9, dovi >= 1.6.7`, `Libs: -lplacebo -lm -ldl`, `Cflags: -DPL_HAVE_PTHREAD -DPL_STATIC`.
- References `vkGetInstanceProcAddr` (MoltenVK), 6 libdovi functions, shaderc and lcms2.

### 2.6 Little CMS (lcms2)

- Upstream: `https://github.com/mm2/Little-CMS`, tag `lcms2.17`, commit `5176347635785e53ee5cee92328f76fda766ecc6`. `LCMS_VERSION 2170` [bin].
- Licence: MIT.
- Source today: `mpvkit/lcms2-build` `2.17.0`. Assets produced by run 20432385218 at `68a37c94f4db` (tag commit differs only in `Package.swift`). `lcms2-all.zip` SHA-256 `8c118b2c04e2440ecf25ffebfa7952ebb09aba83a71378e3b9ed45dae3a6115a`.
- Build system: meson with no library-specific options, so upstream defaults apply [up]:
  - `tests` enabled (yield)
  - `jpeg` auto and `tiff` auto (neither found when cross-compiling)
  - `utils=false`
  - `fastfloat=false` and `threaded=false`. Both of these plug-ins are GPL-3.0 and are not built.
- Headers: `lcms2.h`, `lcms2_plugin.h`.

### 2.7 libdovi (dolby_vision crate, C API)

- Upstream: `https://github.com/quietvoid/dovi_tool`, tag `libdovi-3.3.2`, commit `4fd2b2235c9f93582dd4a00e65ee34a07800afd7`, crate directory `dolby_vision` [up].
  - Crate `dolby_vision` version 3.3.2, edition 2024, `rust-version = "1.85.0"`, licence MIT.
  - `Cargo.lock` is committed in that directory.
  - Dependencies: `bitvec_helpers 3.1.6` (feature `bitstream-io`), `anyhow`, `bitvec`, `crc`, `tinyvec`, and `libc` (via feature `capi`).
- C API metadata: header `libdovi/rpu_parser.h`, pkg-config name `dovi` (consumers require `dovi >= 1.6.7`).
- Resolved runtime crates from `dolby_vision/Cargo.lock` at the tag, for default features plus `capi`: `anyhow 1.0.98`, `bitvec 1.0.1` (with `funty 2.0.0`, `radium 0.7.0`, `tap 1.0.1`, `wyz 0.5.1`), `bitvec_helpers 3.1.6` (with `bitstream-io 2.6.0`), `crc 3.3.0` (with `crc-catalog 2.4.0`), `tinyvec 1.9.0` and `libc 0.2.172`. That is 12 crates, all from crates.io with checksums in the lock file. `roxmltree`, `serde` and `serde_json` are optional and not enabled.
- The build command passes no `--locked`, so Cargo uses the committed lock file but is not prevented from updating it.
- Licence: MIT. Crates MIT, Apache-2.0 or zlib; Rust standard library MIT or Apache-2.0 (per Vivid's notices).
- Source today: `mpvkit/libdovi-build` `3.3.2`. Assets produced by run 20428353657 at `77328e399a42` (tag commit differs only in `Package.swift`). `libdovi-all.zip` SHA-256 `81b85386016a012391c473674ef96e4e494fa76aef2f7b6c102a335e844644f8`.
- Toolchain [ci]: `macos-14`, Xcode 15.4. Rust from `rustup toolchain install nightly --profile complete` and `rustup default nightly`, so the nightly date is whatever was current on 22 December 2025. `cargo install cargo-c`, unpinned. The run logs have expired, so the exact `rustc` and `cargo-c` versions cannot be recovered.

Build [cfg]:
- `cargo cinstall -Zbuild-std=std,panic_abort --release --prefix=<dir> --target=<triple>`, run in `dolby_vision/`, with the environment of 2.0 (CFLAGS and LDFLAGS as above).
- Rust targets:

| Platform | arm64 | arm64e | x86_64 |
| --- | --- | --- | --- |
| iOS device | `aarch64-apple-ios` | n/a | n/a |
| iOS simulator | `aarch64-apple-ios-sim` | n/a | `x86_64-apple-ios` |
| tvOS device | `aarch64-apple-tvos` | `arm64e-apple-tvos` | n/a |
| tvOS simulator | `aarch64-apple-tvos-sim` | n/a | `x86_64-apple-tvos` |

- The tvOS targets and `arm64e-apple-tvos` are Rust tier 3. Building them needs nightly and `-Zbuild-std`.

Result [bin]:
- Archive with an unsorted `__.SYMDEF` symbol table.
- Device and x86_64 objects carry `LC_VERSION_MIN_*` 10.0; arm64 simulator objects carry `LC_BUILD_VERSION` 14.0 (see 1.5).
- References pthread and dispatch. It also defines `___isPlatformVersionAtLeast` (compiler builtins), which Libmpv and Libavcodec happen to resolve against.
- No patches for Apple. The Android-only patch `0001-rpu-validate-trimmed-length-before-crc.patch` is not applied on Apple.

### 2.8 MoltenVK (and Vulkan headers)

- Upstream: `https://github.com/KhronosGroup/MoltenVK`, tag `v1.4.1`, commit `db445ff2042d9ce348c439ad8451112f354b8d2a`. `MVK_VERSION 1.4.1` [up] [bin].
- Licence: Apache-2.0.
- Pinned externals (`ExternalRevisions/` at v1.4.1) [up], with licences:
  - SPIRV-Cross `adec7acbf41a988713cdb85f93f26c8ca5ea863e` (Apache-2.0)
  - SPIRV-Headers `b824a462d4256d720bebb40e78b9eb8f78bbb305` (MIT-style)
  - SPIRV-Tools `262bdab48146c937467f826699a40da0fdfc0f1a` (Apache-2.0)
  - Volk `59660878571aa99e3c9a366bb1d19fdcd701f0e7` (MIT)
  - Vulkan-Headers `6aefb8eb95c8e170d0805fd0f2d02832ec1e099a` = `v1.4.334` (Apache-2.0 or MIT)
  - Vulkan-Tools `013058f74e2356347f8d9317233bc769816c9dfb`
  - cereal `a56bad8bbb770ee266e930c95d37fff2a5be7fea` (BSD-3-Clause)
- Source today: `mpvkit/moltenvk-build` `1.4.1`. Assets produced by run 19818078306 at `ae47104a669e` (tag commit differs only in `Package.swift`). `MoltenVK-all.zip` SHA-256 `9f65e1025f49c55394da475e40fbe1da8dbd10382d730ce81ebc4c5ac40104d1`.
- Build system: MoltenVK's own `fetchDependencies` with one platform flag per platform (`--ios --iossim --tvos --tvossim` for Vivid's four), then MoltenVK's own `make` targets for the same platforms (`ios iossim tvos tvossim`). The xcframework is MoltenVK's own static package (`Package/Release/MoltenVK/static/MoltenVK.xcframework`).
- Source edit: patch `00001-fix-xcode15-build.patch` wraps `supportsApple9 = supportsGPUFam(Apple9, mtlDev);` in `MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm` with `#if MVK_XCODE_15 && !MVK_TVOS && !MVK_VISIONOS`.

Shipped for consumers (`MoltenVK-all.zip`) [bin]:
- `include/` with `vulkan/`, `vk_video/` and `MoltenVK/`. `VK_HEADER_VERSION 334`.
- `pkgconfig-example/<platform>/<arch>/vulkan.pc`: `Name: Vulkan-Loader`, `Version: 1.4.334`, `Libs: -L${libdir} -lMoltenVK -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit`, with `-framework IOKit` added on iOS but not tvOS. This file is generated, not produced by MoltenVK.
- `lib/MoltenVK.xcframework`, byte-identical to the SwiftPM `MoltenVK` slice.
- The static library is a single prelinked object.

Consumer requirements: FFmpeg `--enable-vulkan` needs `vulkan >= 1.3.277` (and checks `>= 1.4.317` for Vulkan 1.4 features); mpv needs `vulkan >= 1.3.238`.

### 2.9 shaderc (with glslang, SPIRV-Tools, SPIRV-Headers)

- Upstream: `https://github.com/google/shaderc`, tag `v2025.5` (tag object `bca2fa0b...`), commit `c4b0af6c3664cd8b33ffddf452514e02a173b4d6`.
- `utils/git-sync-deps` pins from `DEPS` [up]:
  - glslang `7a47e2531cb334982b2a2dd8513dca0a3de4373d`. `GLSLANG_VERSION 16.0.0` [bin].
  - SPIRV-Tools `262bdab48146c937467f826699a40da0fdfc0f1a`
  - SPIRV-Headers `b824a462d4256d720bebb40e78b9eb8f78bbb305`
  - abseil `1315c900e1ddbb08a23e06eeb9a06450052ccb5e`, effcee `08da24ec245a274fea3a128ba50068f163390565`, googletest `1d17ea141d2c11b8917d2c7d029f1c4e2b9769b2` and re2 `4a8cee3dd3c3d81b6fe8b867811e193d5819df07`. These are test-only.
- Licences: shaderc Apache-2.0; glslang BSD-3-Clause, BSD-2-Clause, MIT and Apache-2.0; SPIRV-Tools Apache-2.0; SPIRV-Headers MIT-style.
- Source today: `mpvkit/libshaderc-build` `2025.5.0`. Assets produced by run 20433138455 at `73542fcaa6f0` (tag commit `ed375d78` differs only in `Package.swift`). `libshaderc-all.zip` SHA-256 `1079da73a292e5b2cea6a02fa2208c4935ead79a98043f81708424510e0ab53f`.

CMake options [cfg]: `-DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DENABLE_EXCEPTIONS=ON -DENABLE_GLSLANG_BINARIES=OFF -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF`.

Source edits outside any patch file [cfg]:
- In SPIRV-Tools' `tools/reduce/reduce.cpp` and `tools/fuzz/fuzz.cpp` (under `third_party/spirv-tools/`), the two `std::system` calls in each file are replaced with `popen`-based equivalents. `std::system` is unavailable on tvOS. These tools are not part of the shipped library.

Shipped artefact:
- One framework, `Libshaderc_combined`, from `libshaderc_combined.a`. Headers are `glslang/`, `shaderc/` and `spirv-tools/`.
- In the consumer `pkgconfig-example`, `shaderc.pc` is the combined variant (renamed from `shaderc_combined.pc`), and the original `shaderc.pc` is kept as `shaderc_shared.pc`.

### 2.10 dav1d

- Upstream: `https://github.com/videolan/dav1d` (mirror of `code.videolan.org/videolan/dav1d`), tag `1.5.3` (tag object `0664c109...`), commit `b546257f770768b2c88258c533da38b91a06f737`. `DAV1D_API_VERSION 7.0.0` [bin].
- Licence: BSD-2-Clause.
- Source today: `edde746/libdav1d-build` `1.5.3-neon`, a pre-release.
  - The repository is a fork of `mpvkit/libdav1d-build`. Its only functional change is commit `3714f81146b0`, which sets `-Denable_asm=true` where mpvkit uses `false`.
  - Assets produced by run 28639903812 at `3714f81146b0`. `libdav1d-all.zip` SHA-256 `ae80dd63322cd8acc262f6a825334b363f41c3182cb1a3ec7490c644aef27095`.
  - The build environment is `mpvkit/BuildShared` at branch `main`, which was commit `f5a360068961fc837b92b4fe2cb7f6ab0ee862cd` at build time (minimum OS 14.0).
- Build system: meson. Options [cfg]: `-Denable_asm=true -Denable_tests=false -Denable_tools=false -Denable_examples=false -Dxxhash_muxer=disabled`.
- Host tools: `nasm` (x86_64 asm) and `ninja`.

### 2.11 uavs3d

- Upstream: `https://github.com/uavs3/uavs3d`, branch `master`, unpinned.
  - The build clones the branch head without a tag (`--depth 1`, default branch). At build time (25 July 2026) the head was commit `0e20d2c291853f196c68922a264bcd8471d75b68`, which is also tag `1.2` [up].
  - `version.sh` is run before building.
- Licence: three-clause BSD (`COPYING`).
- Source today: `mpvkit/libuavs3d-build` `1.2.1-fix`. Assets produced by run 30140956213 at `51f936c182af` (tag commit differs only in `Package.swift` and `docs/Package.template.swift`). `libuavs3d-all.zip` SHA-256 `8644c7a8182679dbe762b522356606220bb6d2196a5ec65511eda42ef48b3e7a`. The build environment is `mpvkit/BuildShared` at commit `794a8f559e548dcf0543045c6bf4289dc3513861` (minimum OS 15.0).
- Build system: CMake with `-DCOMPILE_10BIT=1`.
- Source edit: patch `0001-fix-cross-compile.patch` comments out the `uavs3dec` test executable and its `aux_source_directory(./test ...)` in `CMakeLists.txt`.

### 2.12 libbluray (with libudfread)

- Upstream: `https://code.videolan.org/videolan/libbluray.git`, tag `1.4.0` (tag object `0852c0ea...`), commit `9f07fbb2077be7a40b062bcf2463a9941c2a3b13`. Cloned recursively. The submodule `contrib/libudfread` (`https://code.videolan.org/videolan/libudfread.git`) is pinned at gitlink `c3cd5cbb097924557ea4d9da1ff76a74620c51a8`, which is libudfread tag `1.2.0` [up].
- Licence: LGPL-2.1-or-later, and the same for libudfread.
- Source today: `mpvkit/libbluray-build` `1.4.0`. Assets produced by run 20433356876 at `3590f0a3880f` (tag commit differs only in `Package.swift`). `libbluray-all.zip` SHA-256 `c0302f43258ba41d9661dea0be4a7c9c1dd59d30d284ecfbf7319157c8e8a8de`.

Meson options [cfg]: `-Denable_docs=false -Denable_tools=false -Denable_devtools=false -Denable_examples=false -Dbdj_jar=disabled -Djava9=false -Dembed_udfread=true -Dfontconfig=disabled -Dfreetype=enabled -Dlibxml2=enabled`.

Source edits (patch files):
- `0001-fix-no-dadisk.patch`: in `src/file/mount_darwin.c`, DiskArbitration use is guarded by `TARGET_OS_OSX`; in `meson.build`, the DiskArbitration framework is added only when `DiskArbitration/DiskArbitration.h` exists.
- `0002-fix-no-fork-and-exec.patch`: in `src/libbluray/bdj/bdj.c`, `vfork()` and `execl()` are guarded by `TARGET_OS_OSX`, and `java_home_pid` is initialised to `-1`.

Build inputs: FreeType (libass-build 0.17.4). The OpenSSL 3.3.5 prebuilt is also present at build time but is not used.

Result [bin]: references FreeType (9 symbols), system libxml2 and pthread, and no OpenSSL.

### 2.13 uchardet

- Upstream: `https://gitlab.freedesktop.org/uchardet/uchardet`, tag `v0.0.8` (tag object `3ac6d310...`), commit `ae6302a016088ad07177f86d417b20010053632b`.
- Licence: MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later. Vivid uses it under LGPL-2.1-or-later.
- Source today: `mpvkit/libuchardet-build` `0.0.8-xcode`. The assets were re-uploaded on 13 November 2025 by run 19318526426 at `fe0537696919`. That commit is one commit after the tag commit `153d8f6a` and changes only architecture lists: it removes arm64e from iOS device, macOS, Catalyst and visionOS, and leaves tvOS as arm64 and arm64e. `libuchardet-all.zip` SHA-256 `2e530b2d5448a1ca9d1f0a6b3ddf80729a870a6ec6c0f8555bc89c58143f01d1`.
- Build system: CMake with `-DBUILD_BINARY=0`.

### 2.14 OpenSSL

- Upstream: `https://github.com/openssl/openssl`, tag `openssl-3.3.5` (tag object `c45e822d...`), commit `f10934c46fef092d04788f01fd0a4eafe3ef715f`. `OPENSSL_VERSION_TEXT "OpenSSL 3.3.5 30 Sep 2025"` [bin].
- Licence: Apache-2.0.
- Source today: `mpvkit/openssl-build` `3.3.5`. Assets produced by run 20428458744 at `83c78cee8803` (tag commit differs only in `Package.swift`). `openssl-all.zip` SHA-256 `8bc37424aa98fdeac17fd00fbeea7b784a39f1f800cc7f9e0c948d3b169c6f2f`.
- Configure options [cfg]: `--prefix=<dir> no-async no-shared no-dso no-engine no-tests <target>`, with the 2.0 environment. On a case-insensitive file system, `configure` resolves to OpenSSL's `Configure`. `<target>` is:

| Arch | `<target>` |
| --- | --- |
| x86_64 | `darwin64-x86_64` |
| arm64e | `iphoneos-cross` |
| arm64 (all platforms) | `darwin64-arm64` |

- Shipped as two frameworks, `Libssl` (`libssl.a`) and `Libcrypto` (`libcrypto.a`). Each carries the full `openssl/` header set (139 headers).
- Consumers [bin]: only Libavformat references OpenSSL (`Libssl` 39 symbols and `Libcrypto` 62). No other binary in the package does.

### 2.15 LuaJIT (macOS only)

- Upstream: `https://github.com/LuaJIT/LuaJIT.git`, branch `v2.1`, unpinned. The binary reports `LuaJIT 2.1.1762795099`, which corresponds to commit `eba91fceb67a0a0163a9222869bf254c988c48c4` (10 November 2025).
- Licence: MIT.
- Source today: `mpvkit/libluajit-build` `2.1.0-xcode`; assets produced by run 19318514213 at `1fc93b53eff8`. That is one commit after the tag commit and makes the same architecture-list change as for uchardet.
- Built with `make` (`TARGET_SYS=iOS`, `DEFAULT_CC=clang`, `CROSS=<Xcode toolchain>/usr/bin/`, `TARGET_FLAGS="-arch <arch> -isysroot <sdk>"`). `-$(ABIVER)` is removed from `Makefile`, `src/Makefile` and `etc/luajit.pc`. No Catalyst build.
- Linked only on macOS, as a platform-conditional dependency of `_MPVKit`. Not needed by Vivid.

### 2.16 System libraries and frameworks

These come from the SDK and are not built [bin]:
- libxml2 (FFmpeg dash and imf demuxers; libbluray)
- zlib (FFmpeg, FreeType, mpv)
- libiconv (libass, mpv)
- libc++ (shaderc, libplacebo, uchardet, MoltenVK)
- `-licucore` (from the libxml2 pkg-config file)

`bz2`, `expat` and `resolv` are declared as linked libraries in `_FFmpeg`, but no shipped archive references their symbols. FFmpeg is built with `--disable-bzlib` and FreeType with `-Dbzip2=disabled`.

---

## 3. Changes already decided for Vivid, and their knock-on effects

Evidence for the LGPL deltas: Vivid run 38330109119 (`origin/fix/lgpl-media-engine` at `89835c1`, tvOS device). It applied Vivid's `patches/mpv-build/0001-build-mpv-and-ffmpeg-as-lgpl.patch` and the two `0901` patches to mpv-build at the pin, and rebuilt FFmpeg and libmpv. I compared its artefact with today's binaries [ci] [bin].

### 3.1 mpv `-Dgpl=false`

- The enabled-feature list is identical to today's except that `gpl` is gone. The configuration string shows `-Dgpl=false`.
- Upstream gates these options on `gpl` [up]: `cdda`, `dvbin`, `dvdnav`, `jack`, `oss-audio`, `caca`, `direct3d` and `x11`. None is enabled on Apple today, so nothing is lost.
- The resulting libmpv is LGPL-2.1-or-later, provided every applied patch is LGPL-compatible.

### 3.2 FFmpeg without `--enable-gpl`, `--enable-version3` and `delogo`

- The binary reports `libavutil license: LGPL version 2.1 or later`, with `CONFIG_GPL 0` and `CONFIG_VERSION3 0`.
- Among filters, only `vf_delogo` disappears. It is the one GPL-only filter in the explicit list; the other GPL-only filters in upstream `configure` were never enabled.
- `--enable-version3` gated no component in this configuration: no version3 external library (gmp, mbedtls and so on) is used.

### 3.3 `--enable-securetransport` instead of OpenSSL

- `CONFIG_SECURETRANSPORT 1`, `CONFIG_OPENSSL 0`. The `tls` and `https` protocols remain (`tls_protocol_deps_any` includes `securetransport`).

Components lost (LGPL run against today, tvOS arm64):

| Kind | Removed | Count change | Reason [up] |
| --- | --- | --- | --- |
| protocols | `dtls`, `ffrtmpcrypt`, `rtmpe`, `rtmpte` | 42 to 38 | `dtls` needs openssl or schannel; `ffrtmpcrypt` needs gcrypt, gmp, openssl or mbedtls, and `rtmpe`/`rtmpte` select it; `rtmps` stays (it uses `tls`) |
| muxers | `whip` | 183 to 182 | `whip_muxer_deps_any="dtls_protocol"` |
| filters | `delogo` | 64 to 63 | GPL-only (see 3.2) |

Decoders, encoders, demuxers, parsers, bitstream filters and hwaccels are unchanged.

Other effects:
- Upstream `configure` enables Secure Transport only if a link test for the private `SecIdentityCreate` succeeds, plus `SSLCreateContext`. This passed with the tvOS 26.5 SDK in run 38330109119.
- Vivid's `patches/ffmpeg/0001-securetransport-without-private-identity-api.patch` removes the `SecIdentityCreate` reference from `libavformat/tls_securetransport.c` on iOS and tvOS. The workflow asserts that the symbol is not referenced.
- `Security` and `CoreFoundation` must be linked. Both are already in `_FFmpeg`'s linker settings.
- Vivid's own notes on the LGPL branch say Secure Transport is limited to TLS 1.2 and checks against the system trust store. `LucidTLS` turns on `tls-verify` only when `avformat_configuration()` contains `--enable-securetransport`, so that string must stay in the new build's configuration.
- `Libssl` and `Libcrypto` have no remaining consumer on iOS or tvOS, so the new package can drop both. Only Libavformat referenced them; Libbluray does not, even though the OpenSSL prebuilt is present when it is built.
- Licence files and notices would change. Vivid currently ships `OpenSSL-Apache-2.0.txt` and `FFmpeg-GPL-3.0-or-later.txt`. These files were not changed.

### 3.4 `-Dmoltenvk=enabled` removed

- The option exists only with edde746's patch `0001-player-add-moltenvk-context.patch`. Upstream mpv 0.41.0 rejects an unknown `-D`, so the option must go whenever that patch is absent.
- Run 38330109119 still passed it because it used edde746's series.
- `-Dvo-avfoundation=enabled` has the same status: it comes from patch `0004`. Whether to pass it depends on Vivid's own mpv series.

MoltenVK stays a hard link dependency without the option [up] [bin]:
- Upstream mpv `vulkan` requires the `vulkan` pkg-config dependency (`>= 1.3.238`) and a libplacebo built with Vulkan.
- `videotoolbox-pl` requires `vulkan` and CoreVideo.
- Upstream `video/out/vulkan/context.c`, `video/out/vulkan/utils.c` and `video/out/hwdec/hwdec_vulkan.c` call `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceProperties2`, `vkDestroySurfaceKHR` and `vkGetPhysicalDeviceQueueFamilyProperties2` directly. Libmpv references exactly these four plus `vkCreateMetalSurfaceEXT` today.
- `vkCreateMetalSurfaceEXT` comes only from the MoltenVK context. Upstream's Metal surface context (`context_mac.m`) is built only with `cocoa` and `swift`, which means macOS.
- Without the patch, mpv therefore has no Vulkan window context on iOS or tvOS. The `vulkan` and `videotoolbox-pl` features remain.
- Libplacebo references `vkGetInstanceProcAddr`.
- FFmpeg has no link-time Vulkan symbol references, but `--enable-vulkan` needs the Vulkan headers and `vulkan.pc` (`>= 1.3.277`) at configure time.
- The features list loses `moltenvk`.

### 3.5 libass from upstream, unpatched

- Pin 0.17.5, commit `4a05d812`. All meson options used today are upstream options, so the option set needs no change (`-Dasm` enabled on arm64 and arm64e, disabled on x86_64).
- The three edde746 patches add public API and a `threads` meson option. The new APIs are `ASS_FEATURE_FAST_BLUR`, `ass_set_threads`, the image pool, `ASS_FEATURE_CACHE_LAYOUT` and `ASS_FEATURE_MOTION_CACHE`. In edde746's mpv series, `0006-sd-ass-fast-blur-and-render-threads.patch` and `0013-sd-ass-isolate-event-prefetch-renderer.patch` use them.
- Any Vivid mpv patch that relies on those APIs will not build against unpatched libass. Subtitle rendering then runs single-threaded, without the fast-blur or layout-cache paths.
- FFmpeg's `ass` and `subtitles` filters work with upstream libass.

### 3.6 Other knock-ons from replacing edde746's patches

- FFmpeg's link dependency on libdovi exists only through edde746's `0003-videotoolbox-convert-dolby-vision-p7.patch`. Without an equivalent Vivid patch, FFmpeg needs no libdovi include or link flags. Libplacebo still needs libdovi (`PL_HAVE_LIBDOVI`).
- Static libmpv needs no patch [up]. Upstream mpv 0.41.0 declares the library with `library('mpv', ...)`, which honours `default_library=static`, so it yields `libmpv.a`. edde746's `0002-revert-build-static.patch` touches only `osdep/mac/meson.build`, which is not part of iOS or tvOS builds.
- The `videotoolbox.c` Metal-compatibility substitution (2.2) is not a patch file. A clean build must decide whether to reproduce it.

---

## 4. How the xcframeworks are assembled and exposed

### 4.1 Per-platform framework bundle (all except MoltenVK) [bin]

- Bundle `<Name>.framework`, shallow layout on iOS and tvOS:
  - `<Name>`: a static archive, the `lipo -create` of the per-arch `lib<name>.a`
  - `Headers/`
  - `Modules/module.modulemap`
  - `Info.plist`
- macOS bundles use the versioned layout (`Versions/A`, `Versions/Current -> A`, `Resources/Info.plist`, symlinked binary). Not needed by Vivid.
- Names: the static library `lib<x>.a` becomes framework `Lib<x>`. So `libavcodec.a` becomes `Libavcodec` and `libshaderc_combined.a` becomes `Libshaderc_combined`; `lcms2` keeps its name.
- FFmpeg yields seven frameworks, one per `lib*.a`. OpenSSL yields two.

Header layout per framework. Contents at `Headers/` root:

| Framework | `Headers/` |
| --- | --- |
| Libavcodec | 26 files, including `config.h` and `mathops.h` |
| Libavdevice | 3 files |
| Libavfilter | 5 files |
| Libavformat | 6 files, including `config.h` and `os_support.h` |
| Libavutil | 109 files, including 15 `hwcontext_*.h` and the internal headers of 2.2 |
| Libswresample, Libswscale | 3 files each |
| Libmpv | `mpv/` |
| Libass | `ass/` |
| Libfreetype | `freetype2/` |
| Libfribidi | `fribidi/` |
| Libharfbuzz | `harfbuzz/` |
| Libunibreak | 7 files |
| Libplacebo | 19 files plus `shaders/` and `utils/` |
| lcms2 | 2 files |
| Libdovi | `rpu_parser.h` |
| Libdav1d | `dav1d/` |
| Libuavs3d | `uavs3d.h` |
| Libbluray | 9 files |
| Libuchardet | `uchardet/` |
| Libssl, Libcrypto | `openssl/` |
| Libshaderc_combined | `glslang/`, `shaderc/`, `spirv-tools/` |
| Libluajit | `luajit-2.1/` |

- Headers are identical across slices apart from `config.h` paths and per-arch values.

`Modules/module.modulemap`:
- Every framework's module map declares one framework module named after the framework, with the `[system]` attribute, the umbrella directory `"."` (all of `Headers/`) and `export *`.
- Exceptions:
  - `Libavcodec` also excludes `xvmc.h`, `vdpau.h`, `qsv.h`, `dxva2.h`, `d3d11va.h` and `d3d12va.h` (one `exclude header` declaration each).
  - `Libavutil` also excludes `hwcontext_vulkan.h`, `hwcontext_vdpau.h`, `hwcontext_vaapi.h`, `hwcontext_qsv.h`, `hwcontext_opencl.h`, `hwcontext_dxva2.h`, `hwcontext_d3d11va.h`, `hwcontext_d3d12va.h` and `hwcontext_cuda.h`.
- `hwcontext_amf.h`, `hwcontext_drm.h`, `hwcontext_mediacodec.h` and `hwcontext_oh.h` are not excluded, so the Libavutil module fails to build (see 1.3).

`Info.plist` keys and values:

| Key (alphabetical) | Value |
| --- | --- |
| `CFBundleDevelopmentRegion` | `en` |
| `CFBundleExecutable` | `<Name>` |
| `CFBundleIdentifier` | `com.mpvkit.<Name>`, with `_` replaced by `-` (for example `com.mpvkit.Libshaderc-combined`) |
| `CFBundleInfoDictionaryVersion` | `6.0` |
| `CFBundleName` | `<Name>` |
| `CFBundlePackageType` | `FMWK` |
| `CFBundleShortVersionString`, `CFBundleVersion` | `87.88.520` |
| `CFBundleSignature` | `????` |
| `CFBundleSupportedPlatforms` | one of `iPhoneOS`, `iPhoneSimulator`, `AppleTVOS`, `AppleTVSimulator` |
| `MinimumOSVersion` | `100.0` (see 1.7 for why this matters) |
| `NSPrincipalClass` | empty string |

### 4.2 xcframework [bin]

- Created with `xcodebuild -create-xcframework -framework <each platform's .framework> ... -output <Name>.xcframework`.
- Top-level `Info.plist` keys: `AvailableLibraries`, `CFBundlePackageType` (`XFWK`) and `XCFrameworkFormatVersion` `1.0`.
- Each `AvailableLibraries` entry has `BinaryPath` (`<Name>.framework/<Name>`, or `.../Versions/A/<Name>` on macOS), `LibraryIdentifier`, `LibraryPath` (`<Name>.framework`), `SupportedArchitectures`, `SupportedPlatform` (`ios` or `tvos`) and, for simulators, `SupportedPlatformVariant` `simulator`.
- MoltenVK entries instead have `LibraryPath` and `BinaryPath` set to `libMoltenVK.a` and no `HeadersPath`.
- Library identifiers Xcode derives for Vivid's slices: `ios-arm64`, `ios-arm64_x86_64-simulator`, `tvos-arm64_arm64e` and `tvos-arm64_x86_64-simulator`. A tvOS device slice without arm64e would be named `tvos-arm64`, which would break the hard-coded paths in 1.8.

Published form [ci]:
- Each platform is built in a separate CI job. The published xcframework contains every platform's framework.
- edde746 publishes each xcframework as `<Name>-<12-hex content key>.xcframework.zip` on the rolling pre-release `binaries-apple`. mpvkit publishes `<Name>.xcframework.zip` on a versioned release, with a `<Name>.xcframework.checksum.txt` beside it.
- The zip's root entry is `<Name>.xcframework/`.
- The SwiftPM checksum is the output of `swift package compute-checksum <zip>`, which is the SHA-256 of the zip.

Per-platform "-all" zips (`<lib>-all-<key>-<platform>.zip` for edde746; `<lib>-all.zip` for mpvkit) hold:
- `lib/<platform>/thin/<arch>/lib/*.a`
- one `include/`
- `pkgconfig-example/<platform>/<arch>/*.pc`, with absolute paths rewritten to `/path/to/workdir`

### 4.3 SwiftPM exposure [cfg]

- Each xcframework is a `.binaryTarget(name:url:checksum:)` whose name equals the framework and module name.
- The product `MPVKit` exposes them through the dummy source targets `_MPVKit` and `_FFmpeg` (section 1.2).
- Swift code imports binary modules directly (`import Libmpv`). `_MPVKit` and `_FFmpeg` are also importable but empty.
- MoltenVK exposes no module.

---

## 5. Build order, dependencies, CI hardware and time

### 5.1 Build-time prerequisites [cfg]

Each library needs the headers, static libraries and `.pc` files of its prerequisites for the same platform and arch before it is configured. Any build order that respects this table works.

| Library | Prerequisites from this graph | System inputs |
| --- | --- | --- |
| dav1d, FreeType, FriBidi, HarfBuzz, lcms2, libdovi, libunibreak, LuaJIT (macOS only), MoltenVK, OpenSSL, shaderc, uavs3d, uchardet | none | zlib for FreeType |
| FFmpeg | dav1d, FreeType, FriBidi, HarfBuzz, lcms2, libass, libplacebo, MoltenVK (headers and `vulkan.pc`), OpenSSL, shaderc, uavs3d; libdovi only for the Dolby Vision patch (see 3.6) | libxml2, zlib |
| libass | FreeType, FriBidi, HarfBuzz, libunibreak | iconv |
| libbluray | FreeType | libxml2 |
| libplacebo | lcms2, libdovi, MoltenVK (headers and `vulkan.pc`), shaderc | none |
| mpv | FFmpeg libraries, lcms2, libass, libbluray, libplacebo, uchardet, `vulkan` (MoltenVK) | iconv, zlib |

### 5.2 Link-time dependency graph, measured with `nm` on tvOS arm64 [bin]

| Library | Resolves symbols from |
| --- | --- |
| Libmpv | Libass, Libavcodec, Libavdevice, Libavfilter, Libavformat, Libavutil, Libbluray, Libplacebo, Libswresample, Libswscale, Libuchardet, MoltenVK (5 `vk*`), lcms2 |
| Libavcodec | Libavutil, Libswresample, Libdav1d, Libuavs3d, Libshaderc_combined, lcms2, Libdovi (patch) |
| Libavformat | Libavcodec, Libavutil, Libssl, Libcrypto |
| Libavfilter | Libass, Libavcodec, Libavformat, Libavutil, Libplacebo, Libshaderc_combined, Libswresample, Libswscale |
| Libavdevice | Libavformat, Libavutil |
| Libswresample, Libswscale | Libavutil |
| Libplacebo | Libdovi, Libshaderc_combined, MoltenVK (`vkGetInstanceProcAddr`), lcms2 |
| Libass | Libfreetype, Libfribidi, Libharfbuzz, Libunibreak |
| Libbluray | Libfreetype |
| Libssl | Libcrypto |
| MoltenVK, Libshaderc_combined, Libdav1d, Libuavs3d, Libdovi, lcms2, FreeType, FriBidi, HarfBuzz, libunibreak, uchardet | system only |

Shared but harmless definitions: `___isPlatformVersionAtLeast` is also defined in Libdovi, and some libc++ typeinfo symbols are also defined in Libshaderc_combined.

### 5.3 System frameworks the static archives need [bin]

| Library | Needs |
| --- | --- |
| Libmpv | AVFoundation (`AVPlayer`, `AVPlayerItem`, `AVURLAsset`, `AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`, `AVSampleBufferRenderSynchronizer`, `AVAudioSession`), CoreImage (`CIContext`, `CIImage`, `CIColor`), OpenGLES (`EAGLContext`), CoreGraphics, CoreMedia, CoreVideo, AudioToolbox, QuartzCore (`CATransaction`), Metal (`MTLCreateSystemDefaultDevice`), UIKit (`UIScreen`), Foundation, iconv, zlib |
| MoltenVK | Metal, QuartzCore (`CAMetalLayer`), IOSurface, CoreGraphics, Foundation, UIKit (`UIScreen`, `UIView`) |
| Libass | CoreText, CoreFoundation, iconv |
| Libavcodec | VideoToolbox, CoreMedia, CoreVideo, CoreFoundation, AudioToolbox, zlib |
| Libavutil | CoreVideo, CoreFoundation |
| Libavformat | libxml2, zlib |

The package's linker settings do not list OpenGLES, CoreGraphics, CoreText, IOSurface or Foundation (see 1.7).

### 5.4 CI hardware and time, from job start to job end [ci]

Runners:
- edde746 and Vivid use GitHub-hosted `macos-26`.
- mpvkit uses GitHub-hosted `macos-14`.
- Run metadata records no CPU or memory figures, and none were measured here.

| Job | What it compiled | Duration |
| --- | --- | --- |
| edde746 run 36139871015 (libass, FFmpeg, libmpv from source; the rest from prebuilt zips) | iOS device | 7 min 02 s |
| | tvOS device (arm64 and arm64e) | 12 min 39 s |
| | iOS simulator (arm64 and x86_64) | 12 min 58 s |
| | tvOS simulator | 10 min 41 s |
| | Mac Catalyst | 8 min 12 s |
| | macOS | 14 min 57 s |
| | merge and publish | 58 s |
| edde746 run 36015974247 (libass and libmpv) | per platform | 2.5 to 4 min |
| Vivid run 38330109119 (LGPL FFmpeg and libmpv, tvOS device) | build step | 12 min 00 s (job 12 min 30 s; job timeout 45 min) |
| Vivid main runs (libmpv only) | per device platform | about 3 min |
| mpvkit libass-build | unibreak, FreeType, FriBidi, HarfBuzz, libass, all platforms | 17 min 36 s |
| mpvkit openssl-build | | 27 min 03 s |
| mpvkit libdovi-build | | 12 min 08 s |
| mpvkit moltenvk-build | | 70 min 13 s |
| mpvkit libshaderc-build (with split-platform xcframeworks) | | 54 min 52 s |
| mpvkit libplacebo-build (including SPIRV-Cross) | | 10 min 48 s |
| mpvkit libbluray-build | | 2 min 43 s |
| mpvkit lcms2-build | | 2 min 02 s |
| edde746 libdav1d-build | | 5 min 22 s |
| mpvkit libuavs3d-build | | 1 min 40 s |
| mpvkit libuchardet-build | | 1 min 17 s |
| mpvkit libluajit-build | | 2 min 07 s |

Most mpvkit jobs build every Apple platform, including visionOS.

Host tools used:
- Homebrew: autoconf, automake, libtool, ninja, pkg-config, wget, nasm, cmake.
- pip: meson 1.4.2.
- For libdovi: rustup nightly and cargo-c.
- For libplacebo: Python jinja2.
- Xcode: 26.6 for edde746, 15.4 for mpvkit.

---

## 6. Ambiguities and open questions

1. Imports in the forbidden files. Whether `MpvPlayerCoreBase.swift`, `MpvPlayerCore.swift` or `ExternalDisplayManager.swift` import modules other than `Libmpv`, or call C symbols by name (as `LucidTLS` does), is unknown. Keep all 25 module names and the product name `MPVKit` until the caller confirms. Partial evidence: on 13 October 2026 the worktree had uncommitted, in-progress files `iosApp/iosApp/Playback/MPV/Vivid*.swift` (for example `VividPlayerCore.swift` and `VividExternalDisplay.swift`). Among engine modules they import only `Libmpv`, and they use no `@_silgen_name`.
2. Deployment targets. "Configured exactly like today" has no single value: objects carry minos 10.0, 13.0, 14.0, 14.5 or 15.0 depending on the producer. Vivid's targets (iOS 18.0, tvOS 26.0) accept any of these. A uniform choice needs a decision. The package manifest says iOS 15 and tvOS 15.
3. Slices. Vivid links only arm64, on device and simulator. Options are to keep arm64e and x86_64 for parity, or drop them and change the slice names that `use-patched-libmpv.sh` hard-codes. Also decide whether to keep Catalyst, macOS and visionOS slices. Vivid does not need them, and dropping macOS means the `.macOS(.v12)` platform and `Libluajit` can go.
4. Package identity and paths. A new repository URL changes the SwiftPM identity (`mpv-build`) and the `SourcePackages/artifacts/<identity>/` path used by `use-patched-libmpv.sh` and the audio-driver workflow.
5. `MinimumOSVersion` 100.0 and bundle identifiers `com.mpvkit.*`. Should the new frameworks keep these values, or use Vivid's own identifiers? If the value changes, check it against ITMS-90208 first (see 1.7); the exact App Store rule was not verified here.
6. Undeclared system frameworks. OpenGLES, CoreGraphics, CoreText, IOSurface and Foundation are needed by the archives but not declared in the package. They resolve in Vivid's apps, and the source of the OpenGLES link was not found. Decide whether to declare them in the new package. Also decide whether to keep the unused `bz2`, `expat` and `resolv`, and `Libssl`/`Libcrypto` once Secure Transport replaces OpenSSL.
7. Internal FFmpeg headers and the `videotoolbox.c` Metal key substitution. Nothing in Vivid's inspected code uses the internal headers, and whether edde746's mpv patches do was not checked exhaustively. The Metal key edit changes runtime pixel-buffer attributes. Both are outside the patch series, so their status is undecided.
8. libdovi in FFmpeg. It is needed only if Vivid's own FFmpeg series includes Dolby Vision profile 7 conversion through libdovi.
9. Unpinned upstreams today:
   - uavs3d (master head at build time, commit `0e20d2c2`)
   - LuaJIT (v2.1 branch head)
   - Rust nightly and cargo-c for libdovi (versions unrecoverable)
   - BuildShared at `main` for dav1d and uavs3d
   - `Libass`, `Libmpv` and FFmpeg build-host Xcode (image default, 26.6)

   A reproducible rebuild must choose pins; the commits listed above are the ones that match today's binaries.
10. Rust tier-3 targets. Rebuilding libdovi for tvOS (`aarch64-apple-tvos`, `aarch64-apple-tvos-sim`, `x86_64-apple-tvos`) and for arm64e requires nightly with `-Zbuild-std=std,panic_abort`. This is the largest reproducibility risk in the graph.
11. Static libmpv: resolved. Upstream produces `libmpv.a` with `default_library=static` (see 3.6).
12. HarfBuzz and FreeType are old. The prebuilts are FreeType 2.12.1, HarfBuzz 8.1.1 and FriBidi 1.0.12, much older than the versions mpv-build pins for Android (2.14.1, 12.3.2, 1.0.16). "Like today" means the old versions.
13. `-Dvo-avfoundation`. Like `-Dmoltenvk`, it needs an edde746 patch. Whether Vivid's own series provides an equivalent option is outside this spec.
14. Runner hardware. CPU and memory were not recorded in CI metadata (see 5.4).
15. Shipped baseline. Today's device archives already link workflow-rebuilt slices (see 1.7). "Zero regressions" should be measured against those, not only against the package's stock binaries. On tvOS that means the LGPL FFmpeg and libmpv.

---

## Appendix A. FFmpeg components enabled today

Identical on all seven iOS and tvOS arch slices. Names are FFmpeg component names, checked against n8.0.1's registries (`allcodecs.c`, `allformats.c`, `protocols.c`, `parsers.c`, `bitstream_filters.c`, `hwaccels.h`, `allfilters.c`).

The LGPL build removes the `whip` muxer, the `dtls`, `ffrtmpcrypt`, `rtmpe` and `rtmpte` protocols, and the `delogo` filter (section 3).

**Decoders (519):** aac aac_at aac_fixed aac_latm aasc ac3 ac3_at ac3_fixed acelp_kelvin adpcm_4xm adpcm_adx adpcm_afc adpcm_agm adpcm_aica adpcm_argo adpcm_ct adpcm_dtk adpcm_ea adpcm_ea_maxis_xa adpcm_ea_r1 adpcm_ea_r2 adpcm_ea_r3 adpcm_ea_xas adpcm_g722 adpcm_g726 adpcm_g726le adpcm_ima_acorn adpcm_ima_alp adpcm_ima_amv adpcm_ima_apc adpcm_ima_apm adpcm_ima_cunning adpcm_ima_dat4 adpcm_ima_dk3 adpcm_ima_dk4 adpcm_ima_ea_eacs adpcm_ima_ea_sead adpcm_ima_iss adpcm_ima_moflex adpcm_ima_mtf adpcm_ima_oki adpcm_ima_qt adpcm_ima_qt_at adpcm_ima_rad adpcm_ima_smjpeg adpcm_ima_ssi adpcm_ima_wav adpcm_ima_ws adpcm_ima_xbox adpcm_ms adpcm_mtaf adpcm_psx adpcm_sanyo adpcm_sbpro_2 adpcm_sbpro_3 adpcm_sbpro_4 adpcm_swf adpcm_thp adpcm_thp_le adpcm_vima adpcm_xa adpcm_xmd adpcm_yamaha adpcm_zork agm aic alac alac_at alias_pix als amr_nb_at amrnb amrwb amv anm ansi anull apac ape apng aptx aptx_hd apv arbc argo ass asv1 asv2 atrac1 atrac3 atrac3al atrac3p atrac3pal atrac9 aura aura2 av1 avrn avrp avs avui bethsoftvid bfi bink binkaudio_dct binkaudio_rdft bintext bitpacked bmp bmv_audio bmv_video bonk brender_pix c93 cavs cbd2_dpcm ccaption cdgraphics cdtoons cdxl cfhd cinepak clearvideo cljr cllc comfortnoise cook cpia cri cscd cyuv dca dds derf_dpcm dfa dfpwm dirac dnxhd dolby_e dpx dsd_lsbf dsd_lsbf_planar dsd_msbf dsd_msbf_planar dsicinaudio dsicinvideo dss_sp dst dvaudio dvbsub dvdsub dvvideo dxa dxtory dxv eac3 eac3_at eacmv eamad eatgq eatgv eatqi eightbps eightsvx_exp eightsvx_fib escape124 escape130 evrc exr fastaudio ffv1 ffvhuff ffwavesynth fic fits flac flashsv flashsv2 flic flv fmvc fourxm fraps frwu ftr g2m g723_1 g728 g729 gdv gem gif gremlin_dpcm gsm gsm_ms gsm_ms_at h261 h263 h263i h263p h264 hap hca hcom hdr hevc hnm4_video hq_hqa hqx huffyuv hymt iac idcin idf iff_ilbm ilbc ilbc_at imc imm4 imm5 indeo2 indeo3 indeo4 indeo5 interplay_acm interplay_dpcm interplay_video ipu jacosub jpeg2000 jpegls jv kgv1 kmvc lagarith lead libdav1d libuavs3d loco lscr m101 mace3 mace6 magicyuv mdec media100 metasound microdvd mimic misc4 mjpeg mjpegb mlp mmvideo mobiclip motionpixels movtext mp1 mp1_at mp1float mp2 mp2_at mp2float mp3 mp3_at mp3adu mp3adufloat mp3float mp3on4 mp3on4float mpc7 mpc8 mpeg1video mpeg2video mpeg4 mpegvideo mpl2 msa1 mscc msmpeg4v1 msmpeg4v2 msmpeg4v3 msnsiren msp2 msrle mss1 mss2 msvideo1 mszh mts2 mv30 mvc1 mvc2 mvdv mvha mwsc mxpeg nellymoser notchlc nuv on2avc opus osq paf_audio paf_video pam pbm pcm_alaw pcm_alaw_at pcm_bluray pcm_dvd pcm_f16le pcm_f24le pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_lxf pcm_mulaw pcm_mulaw_at pcm_s16be pcm_s16be_planar pcm_s16le pcm_s16le_planar pcm_s24be pcm_s24daud pcm_s24le pcm_s24le_planar pcm_s32be pcm_s32le pcm_s32le_planar pcm_s64be pcm_s64le pcm_s8 pcm_s8_planar pcm_sga pcm_u16be pcm_u16le pcm_u24be pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc pcx pdv pfm pgm pgmyuv pgssub pgx phm photocd pictor pixlet pjs png ppm prores prores_raw prosumer psd ptx qcelp qdm2 qdm2_at qdmc qdmc_at qdraw qoa qoi qpeg qtrle r10k r210 ra_144 ra_288 ralf rasc rawvideo realtext rka rl2 roq roq_dpcm rpza rscc rtv1 rv10 rv20 rv30 rv40 rv60 s302m sami sanm sbc scpr screenpresso sdx2_dpcm sga sgi sgirle sheervideo shorten simbiosis_imx sipr siren smackaud smacker smc smvjpeg snow sol_dpcm sonic sp5x speedhq speex srgc srt ssa stl subrip subviewer subviewer1 sunrast svq1 svq3 tak targa targa_y216 tdsc text theora thp tiertexseqvideo tiff tmv truehd truemotion1 truemotion2 truemotion2rt truespeech tscc tscc2 tta twinvq txd ulti utvideo v210 v210x v308 v408 v410 vb vble vbn vc1 vc1image vcr1 vmdaudio vmdvideo vmix vmnc vnull vorbis vp3 vp4 vp5 vp6 vp6a vp6f vp7 vp8 vp9 vplayer vqa vqc vvc wady_dpcm wavarc wavpack wbmp wcmv webp webvtt wmalossless wmapro wmav1 wmav2 wmavoice wmv1 wmv2 wmv3 wmv3image wnv1 wrapped_avframe ws_snd1 xan_dpcm xan_wc3 xan_wc4 xbin xbm xface xl xma1 xma2 xpm xsub xwd y41p ylc yop yuv4 zero12v zerocodec zlib zmbv

Decoders present in n8.0.1 but not enabled: every `*_mediacodec`, `*_cuvid`, `*_qsv`, `*_amf`, `*_v4l2m2m`, `*_rkmpp`, `*_mmal` and `*_oh` hardware decoder, and every external-library decoder other than libdav1d and libuavs3d (libaom_av1, libopus, libvorbis, libvpx_vp8/vp9, libjxl, libfdk_aac and so on).

**Encoders (190):** a64multi a64multi5 aac aac_at ac3 ac3_fixed adpcm_adx adpcm_argo adpcm_g722 adpcm_g726 adpcm_g726le adpcm_ima_alp adpcm_ima_amv adpcm_ima_apm adpcm_ima_qt adpcm_ima_ssi adpcm_ima_wav adpcm_ima_ws adpcm_ms adpcm_swf adpcm_yamaha alac alac_at alias_pix amv anull apng aptx aptx_hd ass asv1 asv2 av1_vulkan avrp avui bitpacked bmp cfhd cinepak cljr comfortnoise dca dfpwm dnxhd dpx dvbsub dvdsub dvvideo dxv eac3 exr ffv1 ffv1_vulkan ffvhuff fits flac flashsv flashsv2 flv g723_1 gif h261 h263 h263p h264_videotoolbox h264_vulkan hdr hevc_videotoolbox hevc_vulkan huffyuv ilbc_at jpeg2000 jpegls ljpeg magicyuv mjpeg mlp movtext mp2 mp2fixed mpeg1video mpeg2video mpeg4 msmpeg4v2 msmpeg4v3 msrle msvideo1 nellymoser opus pam pbm pcm_alaw pcm_alaw_at pcm_bluray pcm_dvd pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_mulaw_at pcm_s16be pcm_s16be_planar pcm_s16le pcm_s16le_planar pcm_s24be pcm_s24daud pcm_s24le pcm_s24le_planar pcm_s32be pcm_s32le pcm_s32le_planar pcm_s64be pcm_s64le pcm_s8 pcm_s8_planar pcm_u16be pcm_u16le pcm_u24be pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc pcx pfm pgm pgmyuv phm png ppm prores prores_aw prores_ks prores_videotoolbox qoi qtrle r10k r210 ra_144 rawvideo roq roq_dpcm rpza rv10 rv20 s302m sbc sgi smc snow sonic sonic_ls speedhq srt ssa subrip sunrast svq1 targa text tiff truehd tta ttml utvideo v210 v308 v408 v410 vbn vc2 vnull vorbis wavpack wbmp webvtt wmav1 wmav2 wmv1 wmv2 wrapped_avframe xbm xface xsub xwd y41p yuv4 zlib zmbv

**Demuxers (358):** aa aac aax ac3 ac4 ace acm act adf adp ads adx aea afc aiff aix alp amr amrnb amrwb anm apac apc ape apm apng aptx aptx_hd apv aqtitle argo_asf argo_brp argo_cvg asf asf_o ass ast au av1 avi avr avs avs2 avs3 bethsoftvid bfi bfstm bink binka bintext bit bitpacked bmv boa bonk brstm c93 caf cavsvideo cdg cdxl cine codec2 codec2raw concat dash data daud dcstr derf dfa dfpwm dhav dirac dnxhd dsf dsicin dss dts dtshd dv dvbsub dvbtxt dxa ea ea_cdata eac3 epaf evc ffmetadata filmstrip fits flac flic flv fourxm frm fsb fwse g722 g723_1 g726 g726le g728 g729 gdv genh gif gsm gxf h261 h263 h264 hca hcom hevc hls hnm iamf ico idcin idf iff ifv ilbc image2 image2_alias_pix image2_brender_pix image2pipe image_bmp_pipe image_cri_pipe image_dds_pipe image_dpx_pipe image_exr_pipe image_gem_pipe image_gif_pipe image_hdr_pipe image_j2k_pipe image_jpeg_pipe image_jpegls_pipe image_jpegxl_pipe image_pam_pipe image_pbm_pipe image_pcx_pipe image_pfm_pipe image_pgm_pipe image_pgmyuv_pipe image_pgx_pipe image_phm_pipe image_photocd_pipe image_pictor_pipe image_png_pipe image_ppm_pipe image_psd_pipe image_qdraw_pipe image_qoi_pipe image_sgi_pipe image_sunrast_pipe image_svg_pipe image_tiff_pipe image_vbn_pipe image_webp_pipe image_xbm_pipe image_xpm_pipe image_xwd_pipe imf ingenient ipmovie ipu ircam iss iv8 ivf ivr jacosub jpegxl_anim jv kux kvag laf lc3 live_flv lmlm4 loas lrc luodat lvf lxf m4v matroska mca mcc mgsts microdvd mjpeg mjpeg_2000 mlp mlv mm mmf mods moflex mov mp3 mpc mpc8 mpegps mpegts mpegtsraw mpegvideo mpjpeg mpl2 mpsub msf msnwc_tcp msp mtaf mtv musx mv mvi mxf mxg nc nistsphere nsp nsv nut nuv obu ogg oma osq paf pcm_alaw pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_s8 pcm_u16be pcm_u16le pcm_u24be pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc pdv pjs pmp pp_bnk pva pvf qcp qoa r3d rawvideo rcwt realtext redspark rka rl2 rm roq rpl rsd rso rtp rtsp s337m sami sap sbc sbg scc scd sdns sdp sdr2 sds sdx segafilm ser sga shorten siff simbiosis_imx sln smacker smjpeg smush sol sox spdif srt stl str subviewer subviewer1 sup svag svs swf tak tedcaptions thp threedostr tiertexseq tmv truehd tta tty txd ty usm v210 v210x vag vc1 vc1t vividas vivo vmd vobsub voc vpk vplayer vqf vvc w64 wady wav wavarc wc3 webm_dash_manifest webvtt wsaud wsd wsvqa wtv wv wve xa xbin xmd xmv xvag xwma yop yuv4mpegpipe

Not enabled: avisynth, dvdvideo, libgme, libmodplug, libopenmpt, vapoursynth.

**Muxers (183):** a64 ac3 ac4 adts adx aea aiff alp amr amv apm apng aptx aptx_hd apv argo_asf argo_cvg asf asf_stream ass ast au avi avif avm2 avs2 avs3 bit caf cavsvideo codec2 codec2raw crc dash data daud dfpwm dirac dnxhd dts dv eac3 evc f4v ffmetadata fifo filmstrip fits flac flv framecrc framehash framemd5 g722 g723_1 g726 g726le gif gsm gxf h261 h263 h264 hash hds hevc hls iamf ico ilbc image2 image2pipe ipod ircam ismv ivf jacosub kvag latm lc3 lrc m4v matroska matroska_audio mcc md5 microdvd mjpeg mkvtimestamp_v2 mlp mmf mov mp2 mp3 mp4 mpeg1system mpeg1vcd mpeg1video mpeg2dvd mpeg2svcd mpeg2video mpeg2vob mpegts mpjpeg mxf mxf_d10 mxf_opatom null nut obu oga ogg ogv oma opus pcm_alaw pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_s8 pcm_u16be pcm_u16le pcm_u24be pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc psp rawvideo rcwt rm roq rso rtp rtp_mpegts rtsp sap sbc scc segafilm segment smjpeg smoothstreaming sox spdif spx srt stream_segment streamhash sup swf tee tg2 tgp truehd tta ttml uncodedframecrc vc1 vc1t voc vvc w64 wav webm webm_chunk webm_dash_manifest webp webvtt whip wsaud wtv wv yuv4mpegpipe

Not enabled: chromaprint.

**Parsers (64):** aac aac_latm ac3 adx amr apv av1 avs2 avs3 bmp cavsvideo cook cri dca dirac dnxhd dnxuc dolby_e dpx dvaudio dvbsub dvd_nav dvdsub evc ffv1 flac ftr g723_1 g729 gif gsm h261 h263 h264 hdr hevc ipu jpeg2000 jpegxl misc4 mjpeg mlp mpeg4video mpegaudio mpegvideo opus png pnm prores_raw qoi rv34 sbc sipr tak vc1 vorbis vp3 vp8 vp9 vvc webp xbm xma xwd. This is every parser in n8.0.1.

**Bitstream filters (48):** aac_adtstoasc apv_metadata av1_frame_merge av1_frame_split av1_metadata chomp dca_core dovi_rpu dts2pts dump_extradata dv_error_marker eac3_core eia608_to_smpte436m evc_frame_merge extract_extradata filter_units h264_metadata h264_mp4toannexb h264_redundant_pps hapqa_extract hevc_metadata hevc_mp4toannexb imx_dump_header media100_to_mjpegb mjpeg2jpeg mjpega_dump_header mov2textsub mpeg2_metadata mpeg4_unpack_bframes noise null opus_metadata pcm_rechunk pgs_frame_merge prores_metadata remove_extradata setts showinfo smpte436m_to_eia608 text2movsub trace_headers truehd_core vp9_metadata vp9_raw_reorder vp9_superframe vp9_superframe_split vvc_metadata vvc_mp4toannexb. This is every bitstream filter in n8.0.1.

**Hwaccels (15):** av1_videotoolbox av1_vulkan ffv1_vulkan h263_videotoolbox h264_videotoolbox h264_vulkan hevc_videotoolbox hevc_vulkan mpeg1_videotoolbox mpeg2_videotoolbox mpeg4_videotoolbox prores_raw_vulkan prores_videotoolbox vp9_videotoolbox vp9_vulkan

**Protocols (41):** async cache concat concatf crypto data dtls fd ffrtmpcrypt ffrtmphttp file ftp gopher gophers hls http httpproxy https icecast ipfs_gateway ipns_gateway md5 mmsh mmst pipe prompeg rtmp rtmpe rtmps rtmpt rtmpte rtmpts rtp srtp subfile tcp tee tls udp udplite unix

Not enabled: android_content, bluray, libamqp, librist, librtmp*, libsmbclient, libsrt, libssh, libzmq, sctp.

**Filters (64, as registry symbols):** af_aformat af_amix af_anull af_aresample af_areverse af_asetrate af_atempo af_atrim af_equalizer af_firequalizer af_loudnorm af_pan af_superequalizer af_volume asink_abuffer asrc_abuffer vf_ass vf_avgblur_vulkan vf_blend_vulkan vf_bwdif vf_bwdif_vulkan vf_chromaber_vulkan vf_crop vf_delogo vf_estdif vf_flip_vulkan vf_format vf_fps vf_gblur_vulkan vf_hflip vf_hflip_vulkan vf_hwdownload vf_hwmap vf_hwupload vf_idet vf_lenscorrection vf_libplacebo vf_lut vf_lut1d vf_lut2 vf_lut3d vf_lutrgb vf_lutyuv vf_negate vf_nlmeans_vulkan vf_null vf_overlay vf_overlay_vulkan vf_palettegen vf_paletteuse vf_rotate vf_scale vf_scale2ref vf_setpts vf_subtitles vf_transpose vf_trim vf_vflip vf_vflip_vulkan vf_w3fdif vf_xfade_vulkan vf_yadif vsink_buffer vsrc_buffer

`--enable-filter='lut*'` expands to `lut lut1d lut2 lut3d lutrgb lutyuv`. `scale2ref` comes with `scale`.

**Devices:** none (`--disable-devices --disable-indevs --disable-outdevs`). `libavdevice` is still built and shipped.

## Appendix B. Release and tag records [ci]

| Producer | Tag (release created) | Tag commit | Asset-producing run, commit | Other differences |
| --- | --- | --- | --- | --- |
| mpvkit/libass-build | 0.17.4 (2025-12-22; assets 2025-11-19) | 392f5914 | 19487080817, a4d8ea60 | Package.swift |
| mpvkit/libbluray-build | 1.4.0 (2025-12-22) | a25a5f01 | 20433356876, 3590f0a3 | Package.swift |
| mpvkit/openssl-build | 3.3.5 (2025-12-22) | 5634c152 | 20428458744, 83c78cee | Package.swift |
| mpvkit/libdovi-build | 3.3.2 (2025-12-22) | c08af75c | 20428353657, 77328e39 | Package.swift |
| mpvkit/moltenvk-build | 1.4.1 (2025-12-01) | c8bdb96a | 19818078306, ae47104a | Package.swift |
| mpvkit/libshaderc-build | 2025.5.0 (2025-12-22) | ed375d78 | 20433138455, 73542fca | Package.swift |
| mpvkit/lcms2-build | 2.17.0 (2025-12-22) | 9ffcc2ea | 20432385218, 68a37c94 | Package.swift |
| mpvkit/libplacebo-build | 7.351.0-2512 (2025-12-22) | d9ff9205 | 20434622243, 47a712b6 | Package.swift |
| edde746/libdav1d-build | 1.5.3-neon, pre-release (2026-07-03) | 54c75146 | 28639903812, 3714f811 | Package.swift |
| mpvkit/libuavs3d-build | 1.2.1-fix (2026-07-25) | bfb5c5a7 | 30140956213, 51f936c1 | Package.swift, docs template |
| mpvkit/libuchardet-build | 0.0.8-xcode (2025-11-12; assets 2025-11-13) | 153d8f6a | 19318526426, fe053769 | one commit after the tag: iOS arm64e removed |
| mpvkit/libluajit-build | 2.1.0-xcode (2025-11-12; assets 2025-11-13) | a8855621 | 19318514213, 1fc93b53 | one commit after the tag: iOS arm64e removed |
| edde746/mpv-build | `binaries-apple` rolling | pin c6f7e635 | FFmpeg key c04b889c6bf7, libmpv key 4016569ef4b2, libass key dcf94c1d6ebe | per-platform zips dated 2026-09-10 (libass) and 2026-09-14/15 (FFmpeg, libmpv) |

Local evidence copies, all read-only and in the scratchpad:
- `dirty-side/engine-src/build-config/`: build repos at the tags above, `mpvkit_BuildShared`, the LGPL run artefact `lgpl-run-38330109119/` and `assets/` (FFmpeg, libmpv and libass tvOS per-platform zips, `MoltenVK-all.zip`, `libplacebo-all.zip`)
- `bc-tools/`: inspection outputs
