# Lucid Engine

## Apple playback

Lucid Engine powers Apple TV, iPhone and iPad playback. Generate
`iosApp/project.yml` for tvOS or `iosApp/project-ios.yml` for iOS with XcodeGen. Dependency revisions and attribution are
recorded in the [third-party notices](../../THIRD_PARTY_NOTICES.md).
Both app targets use the same pinned media package and retain Vivid’s controls.
VividKit is no longer linked by either app target.

Lucid Engine pins a patched mpv Apple binary package and its Swift Apple bridge. Compressed AC-3/E-AC-3 uses its AVPlayer resource loader; PCM uses
its sample-buffer output. mpv owns scheduling, including the compressed-clock
accounting and host-clock video presentation fixes. Vivid does not insert a
second audio clock, fixed sync offset or HLS server. Source headers are passed
as a typed mpv string list; raw mpv messages are not persisted because they
can contain authenticated source URLs. Structured trial events identify mpv.

Vivid adapts playback state, seek, track selection and stats. Embedded subtitles
use mpv's renderer; external text subtitles use Vivid's existing bounded loader
and overlay. Frame extraction remains unavailable.
Apple rendering mode remains the evidence for a Dolby audio output badge;
source channels or accepted E-AC-3 bytes alone do not establish Atmos output.

The initial revision passed a full arm64 tvOS simulator build and checks for
the pinned dependency graph and custom AVPlayer output in the downloaded
libmpv binaries. The code at `bb4bc1e` also passed an unsigned arm64 physical Apple TV target
build, the pinned-binary checks and 15 production track-ID translation checks
in GitHub Actions. The later buffer and native EOF fixes have been installed on Living Room.
The user confirmed Dune 1, Dune 2, seeking and synchronised playback; earlier
Punisher testing confirmed Dolby Vision. These observations do not establish
Atmos output.

### Builds and diagnostics

The iOS adapter exposes the sample-buffer layer to Vivid’s Picture in Picture
coordinator and forwards PiP state to the media core. Background playback follows
the saved preference. Native AVAsset frame extraction provides scrub previews
for formats Apple can read; unsupported preview formats return no image.
External ASS sidecars currently use the shared text parser, so styled ASS parity
with the retired iOS renderer is not claimed. iOS device playback, PiP and route
verification remain pending.

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for the exact Apple
bridge and binary revisions. Debug builds record allowlisted events in
`Library/Caches/MPVTrial.log`, including numeric native audio heartbeat fields
and fixed audio fault labels. Raw mpv messages and source URLs are excluded.
Audio heartbeats include a matching numeric cache snapshot (input rate, packet
bytes and available per-stream timestamps) to distinguish input starvation
from an output stall. No automatic stall-triggered PCM switch or seek is applied.

The native EOF restart trial is in
`patches/mpv/0001-avfoundation-resume-after-audio-eof.patch`. Its dedicated
`mpv-audio-driver.yml` workflow rebuilds only libmpv from the pinned source,
restoring the remaining dependencies from upstream binaries. For the physical
device trial, replace only the matching physical-device slice in the task’s
resolved artifact cache with that workflow’s verified artifact, then relink
the app: `tvos-arm64_arm64e/Libmpv.framework` for tvOS or
`ios-arm64/Libmpv.framework` for iOS. Native workflow 35028421151 built and
verified both slices. The iPhone build was signed, verified and installed;
physical playback and PiP confirmation remain pending. The package lock still describes the upstream package; a normal
fresh resolution does not include this trial patch. Verify the marker
`resuming compressed feed after audio EOF` in the linked app binary before
installing. Native driver build 34964055136 passed. Device testing showed
compressed audio recovering after silence, but repeated interruptions remained.

The next trial raises the forward demux packet limit from 64 MiB to 256 MiB,
retaining the 16 MiB back buffer. Dune traces repeatedly hit the old limit while
the compressed output requested audio ahead of video. mpv 0.41.0 can mark an
empty stream EOF when the shared packet limit prevents further reads. The larger
budget gives the Apple driver's 16-second startup lead more room; it is a limit,
not a requirement to fill the cache before playback. Device verification of
this change passed initial Dune playback and user-reported seek testing. Diagnostics capture the exact packet-overflow warning
regardless of demuxer prefix and the native feed-resume marker. Generic EOF
messages are labelled as messages, not proof that the media file ended.

Embedded subtitle rendering, first frame,
resume, audio selection and speed changes need physical tvOS testing. At
non-unit speed, the adapter selects PCM before applying
the tempo change, then restores compressed audio after returning to 1x.

Compressed audio stats use the active mpv output codec and selected track's
channel count. The IEC carrier's two channels are not displayed as stereo.
An unreported Apple rendering mode does not hide the known codec; the Atmos
suffix is added only when Apple reports Dolby Atmos. This label change does
not alter output routing, buffering or timing.
