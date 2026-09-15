# Vivid playback engine

## Active tvOS experiment

The `plezy-mpv-experiment` branch starts from KSPlayer checkpoint `575e3c9`;
`ksplayer-trial` retains that checkpoint and the existing PCM/native trials.
Generate `iosApp/project.yml` with XcodeGen to build the isolated mpv
experiment. Restore the KSPlayer source and configuration by switching to
`ksplayer-trial`. KSPlayer sources, patches and its tvOS dependency have been
removed from this experimental branch.
The same app identity and controls are retained; iOS is unchanged. Do not link
the two FFmpeg distributions into the same target.

The experiment pins Plezy's patched mpv Apple binary package and its Swift
Apple bridge. Compressed AC-3/E-AC-3 uses its AVPlayer resource loader; PCM uses
its sample-buffer output. mpv owns scheduling, including the compressed-clock
accounting and host-clock video presentation fixes. Vivid does not insert a
second audio clock, fixed sync offset or HLS server. Source headers are passed
as a typed mpv string list; raw mpv messages are not persisted because they
can contain authenticated source URLs. Structured trial events identify mpv.

Vivid adapts playback state, seek, track selection and stats. Embedded subtitles
use mpv's renderer; external text subtitles use Vivid's existing bounded loader
and overlay. Frame extraction remains unavailable, as in the KSPlayer trial.
Apple rendering mode remains the evidence for a Dolby audio output badge;
source channels or accepted E-AC-3 bytes alone do not establish Atmos output.

The initial revision passed a full arm64 tvOS simulator build and checks for
the pinned dependency graph and custom AVPlayer output in the downloaded
libmpv binaries. The final revision is undergoing an unsigned physical-device
build. This experiment has not been installed or verified on Living Room.
Build success does not establish sync, Dolby Vision or Atmos.

### Retained routes and provenance

The KSPlayer implementation, its timing tests and its device observations remain
on `ksplayer-trial` at `575e3c9`. The earlier PCM checkpoint is `d013ba2`.
The KSPlayer device observations do not validate this mpv implementation.

The iPhone/iPad target still uses VividKit. Generate `iosApp/project-ios.yml`
for iOS; do not combine its FFmpeg packages with the tvOS package graph.

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for the exact Apple
bridge and binary revisions. Debug builds record allowlisted events in
`Library/Caches/MPVTrial.log`. Embedded subtitle rendering, first frame,
resume, audio selection and speed changes need physical tvOS testing. At
non-unit speed, the adapter follows Plezy by selecting PCM before applying
the tempo change, then restores compressed audio after returning to 1x.
