# Lucid Engine patches

These patches change the sources Lucid Engine's FFmpeg and libmpv are built from. The [Lucid native audio driver workflow](../.github/workflows/mpv-audio-driver.yml) applies them to `edde746/mpv-build` at `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` and builds the device frameworks that [`scripts/release/use-patched-libmpv.sh`](../scripts/release/use-patched-libmpv.sh) installs. See [Builds and native audio patch](../docs/cores/player-engine.md#builds-and-native-audio-patch) for the full process.

| Folder | What it changes | Where it is applied |
| --- | --- | --- |
| `mpv-build/` | `0001-build-mpv-and-ffmpeg-as-lgpl.patch` changes mpv-build's build script (`Sources/BuildScripts/XCFrameworkBuild/main.swift`). mpv is built with `-Dgpl=false`. FFmpeg is built without `--enable-gpl`, `--enable-version3` or the GPL-only `delogo` filter, and reads HTTPS through Apple's Secure Transport instead of OpenSSL. | Applied with `git apply` to the mpv-build checkout before anything is built. |
| `ffmpeg/` | `0001-securetransport-without-private-identity-api.patch` changes FFmpeg's Secure Transport backend (`libavformat/tls_securetransport.c`). It compiles out the client certificate path, which needs PEM import and the private `SecIdentityCreate`, when PEM import is unavailable (iOS and tvOS) or on Mac Catalyst. Server certificates are still checked against the system trust store when verification is on. | Copied into mpv-build's FFmpeg patch pool as `0901-vivid-securetransport-without-private-identity-api.patch` and appended to `patches/ffmpeg/series.apple`, so it applies after mpv-build's own FFmpeg patches, including `0011-securetransport-disable-pem-import-for-catalyst.patch`. |
| `mpv/` | `0001-avfoundation-resume-after-audio-eof.patch` changes mpv's AVFoundation audio output (`audio/out/ao_avfoundation.m`). It restarts the compressed feed after audio EOF, improves compressed and PCM startup, resume and recovery on AirPlay, adds the `manage-audio-session`, `compressed-start-grace`, `compressed-first-start-grace`, `compressed-buffer`, `compressed-anchor-start` and `compressed-anchor-resume` driver options, and adds verbose transport traces. | Copied into mpv-build's mpv patch pool as `0901-vivid-audio-eof.patch` and appended to `patches/mpv/series.apple`, so it applies after mpv-build's own mpv patches. |

## Licence

blurbery licenses his own patches in `mpv/`, `mpv-build/` and `ffmpeg/` under the GNU Lesser General Public License, version 2.1 or (at your option) any later version (`LGPL-2.1-or-later`). The patches are not under Vivid's GPL-3.0-only licence.

- `mpv/` and `ffmpeg/` change `audio/out/ao_avfoundation.m` (mpv 0.41.0) and `libavformat/tls_securetransport.c` (FFmpeg n8.0.1). Both files carry an `LGPL-2.1-or-later` licence header upstream, which is the licence the patches use.
- `mpv-build/` changes mpv-build's build script. The mpv-build repository is distributed under GPL-3.0, and the unchanged lines quoted in the patch remain under that licence.

`use-patched-libmpv.sh` matches workflow runs against the whole `patches/` folder, so any change here, including to this file, needs a new workflow run (or an explicit `--run`) before a device build can use its frameworks.
